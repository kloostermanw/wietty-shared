import Testing
import Foundation
@testable import ItermplexShared

/// Deliberately not covered here: `start()`, `stop()`, and the socket receive loop.
/// `RemoteTerminalConnection` has no injection seam over `URLSessionWebSocketTask` by
/// design, since it is a verbatim port of code already running in the macOS app, and
/// adding one would make it harder to audit against the original. The `task === self.socket`
/// identity guard and the `@MainActor` hop in the receive callback are verified by
/// inspection and by production/live-terminal use, not by test.
@MainActor
@Suite struct RemoteTerminalConnectionTests {
    private func connection() -> RemoteTerminalConnection {
        RemoteTerminalConnection(
            connection: RemoteConnection(id: UUID(), name: "B", host: "127.0.0.1", port: 1, token: "t"),
            sessionId: "s1"
        )
    }

    @Test func dataMessagesReachTheDataCallback() {
        let c = connection()
        var received: [UInt8] = []
        c.onData = { received.append(contentsOf: $0) }
        c.handle("{\"type\":\"data\",\"vt\":\"hi\"}")
        #expect(received == Array("hi".utf8))
    }

    @Test func resizeMessagesReachTheResizeCallback() {
        let c = connection()
        var size: (Int, Int)?
        c.onResize = { size = ($0, $1) }
        c.handle("{\"type\":\"resize\",\"cols\":120,\"rows\":40}")
        #expect(size?.0 == 120)
        #expect(size?.1 == 40)
    }

    @Test func endedMessagesReachTheEndedCallback() {
        let c = connection()
        var ended = false
        c.onEnded = { ended = true }
        c.handle("{\"type\":\"ended\"}")
        #expect(ended)
    }

    @Test func garbageFiresNoCallback() {
        let c = connection()
        var fired = false
        c.onData = { _ in fired = true }
        c.onResize = { _, _ in fired = true }
        c.onEnded = { fired = true }
        c.handle("not json")
        c.handle("{\"type\":\"who-knows\"}")
        #expect(!fired)
    }
}
