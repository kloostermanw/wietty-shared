import Testing
import Foundation
@testable import ItermplexShared

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

    @Test func sendBeforeStartIsDropped() {
        // No socket exists yet, so this must not crash and must not be queued.
        connection().send(Array("ls\r".utf8)[...])
    }
}
