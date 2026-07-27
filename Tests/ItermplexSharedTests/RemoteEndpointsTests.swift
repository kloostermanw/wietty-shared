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

    // MARK: - tmux pane ids

    // Session ids used to be iTerm2 GUIDs. They are now tmux pane ids like "%12", and "%"
    // is the percent-encoding escape character: left raw, `%12` is parsed by `URL(string:)`
    // as an escaped `U+0012` control character rather than the literal pane id, so the
    // server ends up attaching to no pane at all. These tests pin the fix: the produced URL
    // must carry the pane id doubly-encoded (`%25` + the original digits) so that a single
    // percent-decode on the server, which is what Hummingbird's `URI` does for query
    // values, recovers the exact original string.

    @Test func paneIdWithDoubleDigitsSurvivesRoundTrip() {
        let url = endpoints.attach(sessionId: "%12")
        #expect(url?.absoluteString == "ws://192.168.1.20:7434/attach?session=%2512&token=tok")
        #expect(decodedQueryValue(url, name: "session") == "%12")
    }

    @Test func paneIdWithSingleDigitSurvivesRoundTrip() {
        let url = endpoints.attach(sessionId: "%3")
        #expect(url?.absoluteString == "ws://192.168.1.20:7434/attach?session=%253&token=tok")
        #expect(decodedQueryValue(url, name: "session") == "%3")
    }

    @Test func paneIdInSessionActionURLsSurvivesRoundTrip() {
        let restart = endpoints.restart(sessionId: "%12")
        #expect(restart?.absoluteString == "http://192.168.1.20:7434/api/sessions/%2512/restart?token=tok")
        #expect(restart?.pathComponents.contains("%12") == true)

        let close = endpoints.close(sessionId: "%12")
        #expect(close?.absoluteString == "http://192.168.1.20:7434/api/sessions/%2512/close?token=tok")
        #expect(close?.pathComponents.contains("%12") == true)
    }

    @Test func tokenNeedingEncodingSurvivesRoundTrip() {
        let withSpecialToken = RemoteEndpoints(
            RemoteConnection(id: UUID(), name: "B", host: "192.168.1.20", port: 7434, token: "a&b=c t")
        )
        let url = withSpecialToken.control
        #expect(url?.absoluteString == "ws://192.168.1.20:7434/control?token=a%26b%3Dc%20t")
        #expect(decodedQueryValue(url, name: "token") == "a&b=c t")
    }

    /// Percent-decodes a single query value the way Hummingbird's `URI.value.percentDecode()`
    /// does server-side, so these tests exercise the whole round trip rather than only the
    /// client-side URL shape.
    private func decodedQueryValue(_ url: URL?, name: String) -> String? {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        return components.queryItems?.first { $0.name == name }?.value
    }
}
