import Testing
import Foundation
@testable import ItermplexShared

@Suite struct RemoteEndpointsTests {
    private let endpoints = RemoteEndpoints(
        RemoteConnection(id: UUID(), name: "B", host: "192.168.1.20", port: 7434, token: "tok")
    )

    @Test func controlSocketURL() {
        #expect(endpoints.control?.absoluteString == "ws://192.168.1.20:7434/control?token=tok")
    }

    @Test func attachSocketURL() {
        #expect(endpoints.attach(sessionId: "s1")?.absoluteString
                == "ws://192.168.1.20:7434/attach?session=s1&token=tok")
    }

    @Test func workspacesURL() {
        #expect(endpoints.workspaces?.absoluteString
                == "http://192.168.1.20:7434/api/workspaces?token=tok")
    }

    @Test func actionURLsUseUppercaseWorkspaceUUIDs() {
        let id = UUID(uuidString: "1B4E28BA-2FA1-11D2-883F-0016D3CCA427")!
        #expect(endpoints.openTerminal(workspaceId: id)?.absoluteString
                == "http://192.168.1.20:7434/api/workspaces/1B4E28BA-2FA1-11D2-883F-0016D3CCA427/terminal?token=tok")
        #expect(endpoints.openClaude(workspaceId: id)?.absoluteString
                == "http://192.168.1.20:7434/api/workspaces/1B4E28BA-2FA1-11D2-883F-0016D3CCA427/claude?token=tok")
    }

    @Test func sessionActionURLs() {
        #expect(endpoints.restart(sessionId: "s1")?.absoluteString
                == "http://192.168.1.20:7434/api/sessions/s1/restart?token=tok")
        #expect(endpoints.close(sessionId: "s1")?.absoluteString
                == "http://192.168.1.20:7434/api/sessions/s1/close?token=tok")
    }

    @Test func aHostWithSpacesYieldsNoURL() {
        let bad = RemoteEndpoints(RemoteConnection(id: UUID(), name: "B", host: "not a host",
                                                  port: 7434, token: "tok"))
        #expect(bad.control == nil)
    }
}
