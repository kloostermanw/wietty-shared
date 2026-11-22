import Testing
import Foundation
@testable import WiettyShared

/// The wrapper only translates and hops, so it is driven through its stream's
/// `handle(_:)` like `TerminalStreamConnectionTests`. Deliveries are queued on the main
/// queue; `drainMain()` suspends the test until everything queued before it has run.
@MainActor
@Suite struct RemoteTerminalConnectionTests {
    private func connection() -> RemoteTerminalConnection {
        RemoteTerminalConnection(
            connection: RemoteConnection(id: UUID(), name: "B", host: "127.0.0.1", port: 1, token: "t"),
            sessionId: "s1"
        )
    }

    private func feed(_ c: RemoteTerminalConnection, _ messages: [StreamMessage]) {
        let hello = StreamMessage.hello(protocolVersion: StreamProtocol.version, session: nil, resize: nil)
        for message in [hello] + messages {
            c.stream.handle(StreamCodec.webSocketFrame(for: message))
        }
    }

    private func drainMain() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test func snapshotRepaintAndDataAllReachOnData() async {
        let c = connection()
        var received: [[UInt8]] = []
        c.onData = { received.append($0) }
        feed(c, [.snapshot([1, 2]), .repaint([3]), .data([4, 5])])
        await drainMain()
        #expect(received == [[1, 2], [3], [4, 5]])
    }

    @Test func resizeCarriesOwn() async {
        let c = connection()
        var sizes: [(Int, Int, Bool)] = []
        c.onResize = { sizes.append(($0, $1, $2)) }
        feed(c, [.resize(cols: 120, rows: 40, own: true), .resize(cols: 80, rows: 24, own: false)])
        await drainMain()
        #expect(sizes.count == 2)
        #expect(sizes.first.map { [$0.0, $0.1] } == [120, 40])
        #expect(sizes.first?.2 == true)
        #expect(sizes.last.map { [$0.0, $0.1] } == [80, 24])
        #expect(sizes.last?.2 == false)
    }

    @Test func endedReachesOnEnded() async {
        let c = connection()
        var reasons: [TerminalEndReason] = []
        c.onEnded = { reasons.append($0) }
        feed(c, [.ended])
        await drainMain()
        #expect(reasons == [.sessionEnded])
    }

    /// Frames arrive from URLSession on a queue of its choosing. The test feeds them from a
    /// background thread for that reason, and every callback must still run on the main
    /// thread.
    @Test func everythingArrivesOnTheMainActor() async {
        let c = connection()
        var onMain: [Bool] = []
        c.onData = { _ in onMain.append(Thread.isMainThread) }
        c.onResize = { _, _, _ in onMain.append(Thread.isMainThread) }
        c.onEnded = { _ in onMain.append(Thread.isMainThread) }
        let stream = c.stream
        let fedOnMain = await Task.detached { Self.feedHere(stream) }.value
        await drainMain()
        #expect(!fedOnMain)
        #expect(onMain == [true, true, true, true])
    }

    /// Feeds a whole session on the calling thread and says whether that was the main one.
    nonisolated private static func feedHere(_ stream: TerminalStreamConnection) -> Bool {
        let messages: [StreamMessage] = [
            .hello(protocolVersion: StreamProtocol.version, session: nil, resize: nil),
            .resize(cols: 80, rows: 24, own: false), .snapshot([1]), .data([2]), .ended,
        ]
        for message in messages { stream.handle(StreamCodec.webSocketFrame(for: message)) }
        return Thread.isMainThread
    }
}
