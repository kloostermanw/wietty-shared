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

    /// A message decoded before `stop()` but not yet delivered is dropped: once `stop()`
    /// returns, the owner hears nothing more from this start.
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
