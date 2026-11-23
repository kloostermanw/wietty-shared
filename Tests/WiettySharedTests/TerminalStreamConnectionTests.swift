import Foundation
import Testing
@testable import WiettyShared

/// Drives the connection one frame at a time through `handle(_:)`, so no test needs a
/// server. Every connection delivers on its own serial queue, which a test drains with
/// `queue.sync {}` before it looks at what arrived.
///
/// Not covered here: the receive loop over a live `URLSessionWebSocketTask`, and so the
/// `task === socket` guard against a stale loop. There is no injection seam over the
/// socket; see the type's doc comment.
struct TerminalStreamConnectionTests {
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _messages: [StreamMessage] = []
        private var _ends: [TerminalEndReason] = []

        var messages: [StreamMessage] { lock.withLock { _messages } }
        var ends: [TerminalEndReason] { lock.withLock { _ends } }

        func message(_ message: StreamMessage) { lock.withLock { _messages.append(message) } }
        func ended(_ reason: TerminalEndReason) { lock.withLock { _ends.append(reason) } }
    }

    private func connection(host: String = "127.0.0.1")
        -> (TerminalStreamConnection, DispatchQueue, Recorder) {
        let queue = DispatchQueue(label: "TerminalStreamConnectionTests")
        let connection = TerminalStreamConnection(
            connection: RemoteConnection(id: UUID(), name: "B", host: host, port: 1, token: "t"),
            sessionId: "s1",
            resize: .reflow,
            callbackQueue: queue
        )
        let recorder = Recorder()
        connection.onMessage = { recorder.message($0) }
        connection.onEnded = { recorder.ended($0) }
        return (connection, queue, recorder)
    }

    private func frame(_ message: StreamMessage) -> StreamCodec.WebSocketFrame {
        StreamCodec.webSocketFrame(for: message)
    }

    private let hello = StreamMessage.hello(protocolVersion: StreamProtocol.version,
                                            session: nil, resize: nil)

    @Test func theServersHelloIsNotDelivered() {
        let (c, queue, recorder) = connection()
        c.handle(frame(hello))
        c.handle(frame(.data([1])))
        queue.sync {}
        #expect(recorder.messages == [.data([1])])
        #expect(recorder.ends.isEmpty)
    }

    /// A version 1 server opens with a data message whose payload is JSON text. That is no
    /// version 2 message at all, and it is certainly not a hello.
    @Test func aFirstMessageThatIsNotAHelloMeansTheServerIsTooOld() {
        let (c, queue, recorder) = connection()
        c.handle(.text(#"{"type":"data","vt":"x"}"#))
        c.handle(frame(hello))
        c.handle(frame(.data([1])))
        queue.sync {}
        #expect(recorder.ends == [.serverTooOld])
        #expect(recorder.messages.isEmpty)
    }

    /// A version 1 server can also open with its resize, which decodes as a perfectly good
    /// version 2 resize. It is still not a hello.
    @Test func aVersionOneResizeFirstMeansTheServerIsTooOld() {
        let (c, queue, recorder) = connection()
        c.handle(.text(#"{"type":"resize","cols":80,"rows":24}"#))
        queue.sync {}
        #expect(recorder.ends == [.serverTooOld])
        #expect(recorder.messages.isEmpty)
    }

    @Test func aHelloWithAnotherVersionMeansTheServerIsTooOld() {
        let (c, queue, recorder) = connection()
        c.handle(frame(.hello(protocolVersion: 1, session: nil, resize: nil)))
        queue.sync {}
        #expect(recorder.ends == [.serverTooOld])
    }

    /// A newer server answers with its own, higher version. That is no reason to call it old.
    @Test func aHelloWithAHigherVersionIsARefusalAskingForAnUpdate() {
        let (c, queue, recorder) = connection()
        c.handle(frame(.hello(protocolVersion: StreamProtocol.version + 1, session: nil, resize: nil)))
        queue.sync {}
        #expect(recorder.ends == [.refused(
            code: "protocol",
            message: "This Mac runs a newer Wietty. Update Wietty on this device.")])
    }

    @Test func aHelloWithALowerVersionMeansTheServerIsTooOld() {
        let (c, queue, recorder) = connection()
        c.handle(frame(.hello(protocolVersion: StreamProtocol.version - 1, session: nil, resize: nil)))
        queue.sync {}
        #expect(recorder.ends == [.serverTooOld])
    }

    /// A concurrent queue is wrapped in a serial one, so the caller cannot break the order
    /// by handing one in.
    @Test func aConcurrentCallbackQueueStillDeliversInOrderAndOneAtATime() {
        let queue = DispatchQueue(label: "concurrent", attributes: .concurrent)
        let c = TerminalStreamConnection(
            connection: RemoteConnection(id: UUID(), name: "B", host: "127.0.0.1", port: 1, token: "t"),
            sessionId: "s1", resize: .reflow, callbackQueue: queue)
        let count = 200
        let recorder = Recorder()
        let gate = ConcurrencyGate()
        let done = DispatchSemaphore(value: 0)
        c.onMessage = { message in
            gate.enter()
            usleep(50)
            recorder.message(message)
            gate.leave()
            if recorder.messages.count == count { done.signal() }
        }
        c.handle(frame(hello))
        for i in 0..<count { c.handle(frame(.data([UInt8(i)]))) }
        #expect(done.wait(timeout: .now() + 10) == .success)
        #expect(recorder.messages == (0..<count).map { .data([UInt8($0)]) })
        #expect(gate.maximum == 1)
    }

    @Test func anErrorEndsWithItsReason() {
        let (c, queue, recorder) = connection()
        c.handle(frame(hello))
        c.handle(frame(.error(code: "protocol", message: "x")))
        c.handle(frame(.data([1])))
        queue.sync {}
        #expect(recorder.ends == [.refused(code: "protocol", message: "x")])
        #expect(recorder.messages.isEmpty)
    }

    /// An error in place of the hello is the server refusing, not the server being old.
    @Test func anErrorInPlaceOfTheHelloIsARefusal() {
        let (c, queue, recorder) = connection()
        c.handle(frame(.error(code: "unknownSession", message: "gone")))
        queue.sync {}
        #expect(recorder.ends == [.refused(code: "unknownSession", message: "gone")])
    }

    @Test func endedEndsTheSession() {
        let (c, queue, recorder) = connection()
        c.handle(frame(hello))
        c.handle(frame(.data([1])))
        c.handle(frame(.ended))
        c.handle(frame(.data([2])))
        c.handle(frame(.ended))
        queue.sync {}
        #expect(recorder.messages == [.data([1])])
        #expect(recorder.ends == [.sessionEnded])
    }

    @Test func messagesKeepTheirOrder() {
        let (c, queue, recorder) = connection()
        let expected: [StreamMessage] = [
            .resize(cols: 120, rows: 40, own: true),
            .snapshot([0x1B, 0x63]),
            .data([0x41]),
            .repaint([0x1B, 0x5B, 0x48]),
        ]
        c.handle(frame(hello))
        expected.forEach { c.handle(frame($0)) }
        queue.sync {}
        #expect(recorder.messages == expected)
    }

    /// After the hello, a frame this client cannot read is a newer server saying something
    /// it does not need, so it is skipped and the stream goes on.
    @Test func anUnreadableFrameAfterTheHelloIsSkipped() {
        let (c, queue, recorder) = connection()
        c.handle(frame(hello))
        c.handle(.text(#"{"type":"something-new"}"#))
        c.handle(.text("not json"))
        c.handle(.binary([0x7F, 0x01]))
        c.handle(.binary([]))
        c.handle(frame(hello))
        c.handle(frame(.data([1])))
        queue.sync {}
        #expect(recorder.messages == [.data([1])])
        #expect(recorder.ends.isEmpty)
    }

    @Test func stopByTheOwnerDoesNotFireOnEnded() {
        let (c, queue, recorder) = connection()
        c.handle(frame(hello))
        c.stop()
        c.handle(frame(.data([1])))
        c.handle(frame(.ended))
        queue.sync {}
        #expect(recorder.messages.isEmpty)
        #expect(recorder.ends.isEmpty)
    }

    /// A message decoded before `stop()` but not yet delivered is dropped. Nothing is
    /// running on the callback queue while `stop()` runs here, so nothing gets through.
    @Test func nothingIsDeliveredAfterStopReturns() {
        let (c, queue, recorder) = connection()
        queue.suspend()
        c.handle(frame(hello))
        c.handle(frame(.data([1])))
        c.handle(frame(.ended))
        c.stop()
        queue.resume()
        queue.sync {}
        #expect(recorder.messages.isEmpty)
        #expect(recorder.ends.isEmpty)
    }

    @Test func aURLThatCannotBeBuiltEndsAsConnectionLost() {
        let (c, queue, recorder) = connection(host: "not a host")
        c.start()
        queue.sync {}
        #expect(recorder.ends == [.connectionLost])
        #expect(recorder.messages.isEmpty)
    }
}

/// Counts how many callers are inside at once, and remembers the most there ever were.
final class ConcurrencyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var inside = 0
    private var _maximum = 0
    var maximum: Int { lock.withLock { _maximum } }
    func enter() { lock.withLock { inside += 1; _maximum = max(_maximum, inside) } }
    func leave() { lock.withLock { inside -= 1 } }
}

/// A socket the test drives by hand. Receives and send completions are both parked
/// until the test fires them, as URLSession, which always calls back later and on a queue
/// of its own, never from inside the call.
final class FakeTransport: WebSocketTransport, @unchecked Sendable {
    typealias ReceiveHandler = @Sendable (Result<URLSessionWebSocketTask.Message, any Error>) -> Void
    typealias SendHandler = @Sendable ((any Error)?) -> Void

    struct Failure: Error {}

    private let lock = NSLock()
    private var receives: [ReceiveHandler] = []
    private var sendCompletions: [SendHandler] = []
    private var _sent: [URLSessionWebSocketTask.Message] = []
    private var _resumed = false
    private var _cancelled = false
    private var _maximumMessageSize = 1 << 20   // URLSession's default
    private var _sizeWhenResumed: Int?

    var maximumMessageSize: Int {
        get { lock.withLock { _maximumMessageSize } }
        set { lock.withLock { _maximumMessageSize = newValue } }
    }
    /// What `maximumMessageSize` was when `resume()` was called, or nil before then.
    var sizeWhenResumed: Int? { lock.withLock { _sizeWhenResumed } }

    var pendingReceives: Int { lock.withLock { receives.count } }
    var resumed: Bool { lock.withLock { _resumed } }
    var cancelled: Bool { lock.withLock { _cancelled } }
    /// What was sent, as the frames `StreamCodec` reads.
    var sent: [StreamCodec.WebSocketFrame] {
        lock.withLock { _sent }.map { message in
            switch message {
            case .string(let text): return .text(text)
            case .data(let data): return .binary(Array(data))
            @unknown default: return .binary([])
            }
        }
    }
    /// What was sent, decoded.
    var sentMessages: [StreamMessage?] { sent.map(StreamCodec.message(from:)) }
    /// The bytes of every data message sent, joined.
    var sentInput: [UInt8] {
        sentMessages.flatMap { message -> [UInt8] in
            if case .data(let bytes) = message { return bytes }
            return []
        }
    }

    func resume() {
        lock.withLock {
            _resumed = true
            _sizeWhenResumed = _maximumMessageSize
        }
    }

    func receive(completionHandler: @escaping ReceiveHandler) {
        lock.withLock { receives.append(completionHandler) }
    }

    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping SendHandler) {
        lock.withLock {
            _sent.append(message)
            sendCompletions.append(completionHandler)
        }
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.withLock { _cancelled = true }
    }

    /// Completes the oldest parked receive, as URLSession would.
    func complete(_ result: Result<URLSessionWebSocketTask.Message, any Error>) {
        let handler: ReceiveHandler? = lock.withLock { receives.isEmpty ? nil : receives.removeFirst() }
        handler?(result)
    }

    func deliver(_ message: StreamMessage) {
        switch StreamCodec.webSocketFrame(for: message) {
        case .text(let text): complete(.success(.string(text)))
        case .binary(let bytes): complete(.success(.data(Data(bytes))))
        }
    }

    /// Completes every parked send with `error`.
    func completeSends(with error: (any Error)?) {
        let handlers = lock.withLock { () -> [SendHandler] in
            defer { sendCompletions = [] }
            return sendCompletions
        }
        handlers.forEach { $0(error) }
    }
}

/// The receive loop and the writes, driven through `FakeTransport` instead of a live
/// server.
struct TerminalStreamSocketLoopTests {
    typealias Recorder = TerminalStreamConnectionTests.Recorder

    final class Factory: @unchecked Sendable {
        private let lock = NSLock()
        private var _made: [FakeTransport] = []
        var made: [FakeTransport] { lock.withLock { _made } }
        func make(_ url: URL) -> any WebSocketTransport {
            let transport = FakeTransport()
            lock.withLock { _made.append(transport) }
            return transport
        }
    }

    private let hello = StreamMessage.hello(protocolVersion: StreamProtocol.version,
                                            session: nil, resize: nil)

    private func connection() -> (TerminalStreamConnection, DispatchQueue, Recorder, Factory) {
        let queue = DispatchQueue(label: "TerminalStreamSocketLoopTests")
        let factory = Factory()
        let connection = TerminalStreamConnection(
            connection: RemoteConnection(id: UUID(), name: "B", host: "127.0.0.1", port: 1, token: "t"),
            sessionId: "s1", resize: .reflow, callbackQueue: queue,
            transport: { factory.make($0) })
        let recorder = Recorder()
        connection.onMessage = { recorder.message($0) }
        connection.onEnded = { recorder.ended($0) }
        return (connection, queue, recorder, factory)
    }

    /// Starts, stops and starts again, and hands back both sockets. The old one still has
    /// its receive parked, which is what a stale completion arrives through.
    private func restarted(_ c: TerminalStreamConnection, _ factory: Factory,
                           beforeStop: (FakeTransport) -> Void = { _ in }) throws
        -> (old: FakeTransport, new: FakeTransport) {
        c.start()
        let old = try #require(factory.made.first)
        beforeStop(old)
        c.stop()
        c.start()
        let new = try #require(factory.made.last)
        #expect(old !== new)
        #expect(old.cancelled)
        #expect(old.pendingReceives == 1)
        return (old, new)
    }

    @Test func startResumesTheSocketAndWaitsForAFrame() throws {
        let (c, _, _, factory) = connection()
        c.start()
        let socket = try #require(factory.made.first)
        #expect(socket.resumed)
        #expect(socket.pendingReceives == 1)
        c.start()
        #expect(factory.made.count == 1)
    }

    /// A snapshot is one message, and with real history it is larger than URLSession's
    /// default limit of 1 MiB. The socket must be told before it opens.
    @Test func theSocketAcceptsTheProtocolsLargestMessageBeforeItOpens() throws {
        let (c, _, _, factory) = connection()
        c.start()
        let socket = try #require(factory.made.first)
        #expect(socket.sizeWhenResumed == StreamProtocol.maxMessageSize)
    }

    /// The production socket is the one the public initializer makes: a real
    /// `URLSessionWebSocketTask`, inspected here without being resumed, so nothing connects.
    /// Setting the limit through `WebSocketTransport`, as `start()` does, must reach the
    /// task's own property and not stop at some default of the protocol.
    @Test func theLimitReachesTheRealSocket() throws {
        let url = try #require(URL(string: "ws://127.0.0.1:1/attach"))
        let transport = TerminalStreamConnection.urlSessionTransport(url)
        defer { transport.cancel(with: .goingAway, reason: nil) }
        let task = try #require(transport as? URLSessionWebSocketTask)
        #expect(task.state == .suspended)
        #expect(task.maximumMessageSize == 1 << 20)   // URLSession's default, too small
        transport.maximumMessageSize = StreamProtocol.maxMessageSize
        #expect(task.maximumMessageSize == StreamProtocol.maxMessageSize)
    }

    @Test func stringAndDataMapToTextAndBinaryFrames() throws {
        let (c, queue, recorder, factory) = connection()
        c.start()
        let socket = try #require(factory.made.first)
        socket.deliver(hello)                                   // a text frame
        socket.complete(.success(.data(Data([0x02, 0x41]))))   // a binary data frame
        socket.complete(.success(.string(#"{"type":"resize","cols":80,"rows":24,"own":true}"#)))
        queue.sync {}
        #expect(recorder.messages == [.data([0x41]), .resize(cols: 80, rows: 24, own: true)])
        #expect(socket.pendingReceives == 1)
    }

    // MARK: The stale socket guard. Each of these fails with the `task === socket` check
    // taken out of `process` and `end`.

    @Test func aStaleDataFrameIsNotDeliveredIntoTheNewSession() throws {
        let (c, queue, recorder, factory) = connection()
        let (old, new) = try restarted(c, factory)
        new.deliver(hello)
        old.deliver(.data([9]))
        #expect(old.pendingReceives == 0)
        new.deliver(.data([1]))
        queue.sync {}
        #expect(recorder.messages == [.data([1])])
        #expect(recorder.ends.isEmpty)
        #expect(new.pendingReceives == 1)
    }

    @Test func aStaleHelloDoesNotAnswerForTheNewSocket() throws {
        let (c, queue, recorder, factory) = connection()
        let (old, new) = try restarted(c, factory)
        old.deliver(hello)
        new.deliver(.data([1]))
        queue.sync {}
        #expect(recorder.ends == [.serverTooOld])
        #expect(recorder.messages.isEmpty)
    }

    @Test func aStaleFailureDoesNotEndTheNewSession() throws {
        let (c, queue, recorder, factory) = connection()
        let (old, new) = try restarted(c, factory)
        new.deliver(hello)
        old.complete(.failure(FakeTransport.Failure()))
        new.deliver(.data([1]))
        queue.sync {}
        #expect(recorder.ends.isEmpty)
        #expect(recorder.messages == [.data([1])])
    }

    @Test func aStaleSendFailureDoesNotEndTheNewSession() throws {
        let (c, queue, recorder, factory) = connection()
        let (old, new) = try restarted(c, factory) { old in
            old.deliver(hello)
            c.send([1])
        }
        #expect(old.sent.count == 1)
        new.deliver(hello)
        old.completeSends(with: FakeTransport.Failure())
        new.deliver(.data([2]))
        queue.sync {}
        #expect(recorder.ends.isEmpty)
        #expect(recorder.messages == [.data([2])])
    }

    // MARK: Ends

    @Test func aFailureEndsAsConnectionLostOnce() throws {
        let (c, queue, recorder, factory) = connection()
        c.start()
        let socket = try #require(factory.made.first)
        socket.deliver(hello)
        c.send([1])                                            // parked, to fail later
        socket.complete(.failure(FakeTransport.Failure()))
        #expect(socket.pendingReceives == 0)
        socket.completeSends(with: FakeTransport.Failure())   // a second failing completion
        queue.sync {}
        #expect(recorder.ends == [.connectionLost])
        #expect(socket.cancelled)
    }

    /// A send still in flight when the session ends fails afterwards. The end has already
    /// been told, and it was `sessionEnded`.
    @Test func endedThenAFailureEndsAsSessionEndedOnly() throws {
        let (c, queue, recorder, factory) = connection()
        c.start()
        let socket = try #require(factory.made.first)
        socket.deliver(hello)
        c.send([1])
        socket.deliver(.ended)
        #expect(socket.pendingReceives == 0)
        socket.completeSends(with: FakeTransport.Failure())
        queue.sync {}
        #expect(recorder.ends == [.sessionEnded])
    }

    @Test func aFailedSendEndsAsConnectionLostOnce() throws {
        let (c, queue, recorder, factory) = connection()
        c.start()
        let socket = try #require(factory.made.first)
        socket.deliver(hello)
        c.send([1])
        c.send([2])
        socket.completeSends(with: FakeTransport.Failure())   // both fail
        queue.sync {}
        #expect(recorder.ends == [.connectionLost])
        #expect(socket.cancelled)
        // The cancelled socket's parked receive then fails as well. That is the same end.
        socket.complete(.failure(FakeTransport.Failure()))
        queue.sync {}
        #expect(recorder.ends == [.connectionLost])
    }

    @Test func aSendThatFailsAfterStopEndsNothing() throws {
        let (c, queue, recorder, factory) = connection()
        c.start()
        let socket = try #require(factory.made.first)
        socket.deliver(hello)
        c.send([1])
        c.stop()
        socket.completeSends(with: FakeTransport.Failure())
        queue.sync {}
        #expect(recorder.ends.isEmpty)
    }

    // MARK: Writes

    @Test func sendWritesABinaryDataFrameAndClaimATextResize() throws {
        let (c, _, _, factory) = connection()
        c.start()
        let socket = try #require(factory.made.first)
        socket.deliver(hello)
        c.send([0x41, 0xFF])
        c.claim(cols: 100, rows: 30)
        #expect(socket.sent.count == 2)
        #expect(socket.sent.first == .binary([0x02, 0x41, 0xFF]))
        guard case .text = socket.sent.last else {
            Issue.record("a claim must be a text frame"); return
        }
        #expect(socket.sent.last.flatMap(StreamCodec.message(from:)) == .resize(cols: 100, rows: 30, own: false))
    }

    /// Typing before the server has answered is not lost: it is written, after the claim,
    /// the moment the hello is accepted, and before anything sent later.
    @Test func inputAndAClaimBeforeTheHelloAreWrittenWhenItArrives() throws {
        let (c, _, _, factory) = connection()
        c.start()
        let socket = try #require(factory.made.first)
        c.send([1, 2])
        c.claim(cols: 80, rows: 24)
        c.send([3])
        #expect(socket.sent.isEmpty)
        socket.deliver(hello)
        c.send([4])
        #expect(socket.sentMessages.first == .resize(cols: 80, rows: 24, own: false))
        #expect(socket.sentMessages.dropFirst().allSatisfy {
            if case .data = $0 { return true } else { return false }
        })
        #expect(socket.sentInput == [1, 2, 3, 4])
        #expect(socket.sentMessages.last == .data([4]))
    }

    private func dataFrames(_ socket: FakeTransport) -> [[UInt8]] {
        socket.sentMessages.compactMap { message in
            if case .data(let bytes) = message { return bytes }
            return nil
        }
    }

    /// The server closes the socket with 1009 on an inbound message over 1 MiB, so a large
    /// paste goes out in frames of at most 64 KiB.
    @Test func largeInputIsSplitIntoFramesOfAtMost64KiB() throws {
        let (c, _, _, factory) = connection()
        c.start()
        let socket = try #require(factory.made.first)
        socket.deliver(hello)
        let input = (0..<(200 * 1024)).map { UInt8($0 % 251) }
        c.send(input)
        let frames = dataFrames(socket)
        #expect(socket.sentMessages.count == 4)
        #expect(frames.count == 4)
        #expect(frames.allSatisfy { $0.count <= 64 * 1024 })
        #expect(Array(frames.joined()) == input)
    }

    @Test func exactly64KiBIsOneFrameAndOneMoreByteIsTwo() throws {
        let (c, _, _, factory) = connection()
        c.start()
        let socket = try #require(factory.made.first)
        socket.deliver(hello)
        c.send(Array(repeating: 7, count: 64 * 1024))
        #expect(dataFrames(socket).count == 1)
        c.send(Array(repeating: 8, count: 64 * 1024 + 1))
        let frames = dataFrames(socket)
        #expect(frames.count == 3)
        #expect(frames[1].count == 64 * 1024)
        #expect(frames[2] == [8])
    }

    @Test func heldInputIsFlushedInOrderWithinTheFrameLimit() throws {
        let (c, _, _, factory) = connection()
        c.start()
        let socket = try #require(factory.made.first)
        c.send([1, 2])
        c.claim(cols: 80, rows: 24)
        c.send(Array(repeating: 9, count: 100 * 1024))
        socket.deliver(hello)
        #expect(socket.sentMessages.first == .resize(cols: 80, rows: 24, own: false))
        let frames = dataFrames(socket)
        #expect(frames.allSatisfy { $0.count <= 64 * 1024 })
        let joined = Array(frames.joined())
        #expect(joined.count == TerminalStreamConnection.maxHeldInput)
        #expect(joined.suffix(10) == Array(repeating: 9, count: 10))
    }

    @Test func concurrentLargeSendsDoNotInterleaveTheirFrames() throws {
        let (c, _, _, factory) = connection()
        c.start()
        let socket = try #require(factory.made.first)
        socket.deliver(hello)
        let a = Array(repeating: UInt8(0xAA), count: 300 * 1024)
        let b = Array(repeating: UInt8(0xBB), count: 300 * 1024)
        DispatchQueue.concurrentPerform(iterations: 2) { i in c.send(i == 0 ? a : b) }
        let frames = dataFrames(socket)
        #expect(frames.count == 10)
        let tags = frames.map { $0.first }
        // Each call's five frames are adjacent: the tag changes at most once.
        #expect(zip(tags, tags.dropFirst()).filter { $0 != $1 }.count == 1)
        #expect(frames.allSatisfy { Set($0).count == 1 })
    }

    /// The server answers once per claim it receives, and `GridOwnership` counts every
    /// claim made, so no early claim may be folded into another.
    @Test func everyClaimBeforeTheHelloIsWrittenInOrderBeforeTheInput() throws {
        let (c, _, _, factory) = connection()
        c.start()
        let socket = try #require(factory.made.first)
        c.claim(cols: 80, rows: 24)
        c.send([1])
        c.claim(cols: 132, rows: 50)
        socket.deliver(hello)
        #expect(socket.sentMessages == [
            .resize(cols: 80, rows: 24, own: false),
            .resize(cols: 132, rows: 50, own: false),
            .data([1]),
        ])
    }

    @Test func atMostTheLatestHeldClaimsAreKept() throws {
        let (c, _, _, factory) = connection()
        c.start()
        let socket = try #require(factory.made.first)
        let limit = TerminalStreamConnection.maxHeldClaims
        #expect(limit == 64)
        for i in 1...(limit + 1) { c.claim(cols: i, rows: 24) }
        socket.deliver(hello)
        #expect(socket.sentMessages == (2...(limit + 1)).map { .resize(cols: $0, rows: 24, own: false) })
    }

    /// The whole round trip the iPad depends on: a viewer counts two early claims, the
    /// server answers each claim it received with `own: true`, then another viewer takes
    /// the grid. The viewer must no longer think it owns it.
    @Test func earlyClaimsAndTheirAnswersBalanceInGridOwnership() throws {
        let (c, queue, recorder, factory) = connection()
        var ownership = GridOwnership()
        c.start()
        let socket = try #require(factory.made.first)
        c.claim(cols: 80, rows: 24); ownership.claimSent()
        c.claim(cols: 100, rows: 30); ownership.claimSent()
        socket.deliver(hello)
        for case let .resize(cols, rows, _)? in socket.sentMessages {
            socket.deliver(.resize(cols: cols, rows: rows, own: true))
        }
        socket.deliver(.resize(cols: 120, rows: 40, own: false))
        queue.sync {}
        for case let .resize(_, _, own) in recorder.messages { ownership.resizeReceived(own: own) }
        #expect(recorder.messages.count == 3)
        #expect(!ownership.isOwner)
    }

    @Test func heldInputKeepsTheNewestBytesWithinTheLimit() throws {
        let (c, _, _, factory) = connection()
        c.start()
        let socket = try #require(factory.made.first)
        let limit = TerminalStreamConnection.maxHeldInput
        let first = (0..<limit).map { UInt8($0 % 251) }
        let second: [UInt8] = Array(repeating: 0xEE, count: 100)
        c.send(first)
        c.send(second)
        socket.deliver(hello)
        #expect(socket.sentInput == Array(first.dropFirst(100)) + second)
        #expect(socket.sentInput.count == limit)
    }

    @Test func heldInputIsDiscardedWhenTheFirstMessageIsNotAHello() throws {
        let (c, queue, recorder, factory) = connection()
        c.start()
        let socket = try #require(factory.made.first)
        c.send([1])
        c.claim(cols: 80, rows: 24)
        socket.deliver(.data([9]))
        queue.sync {}
        #expect(recorder.ends == [.serverTooOld])
        #expect(socket.sent.isEmpty)
    }

    @Test func heldInputIsDiscardedByStop() throws {
        let (c, _, _, factory) = connection()
        let (old, new) = try restarted(c, factory) { _ in c.send([1]) }
        new.deliver(hello)
        #expect(old.sent.isEmpty)
        #expect(new.sent.isEmpty)
    }

    @Test func nothingIsHeldOrWrittenBeforeStart() throws {
        let (c, _, _, factory) = connection()
        c.send([1])
        c.claim(cols: 80, rows: 24)
        c.start()
        let socket = try #require(factory.made.first)
        socket.deliver(hello)
        #expect(socket.sent.isEmpty)
    }

    @Test func nothingIsWrittenAfterAnEnd() throws {
        let (c, _, _, factory) = connection()
        c.start()
        let socket = try #require(factory.made.first)
        socket.deliver(hello)
        socket.deliver(.ended)
        c.send([1])
        c.claim(cols: 80, rows: 24)
        #expect(socket.sent.isEmpty)
    }
}
