import Testing
import Foundation
@testable import WiettyShared

@Suite struct RemoteSnapshotDecoderTests {
    /// Builds snapshot JSON text from a dictionary, so tests read like the wire
    /// format rather than like escaped string literals.
    private func snapshot(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)!
    }

    @Test func decodesWorkspacesGitAndSessions() throws {
        let wsId = UUID()
        let sessionId = UUID()
        let text = snapshot([
            "type": "snapshot",
            "workspaces": [[
                "id": wsId.uuidString, "name": "demo",
                "git": ["branch": "main", "ahead": 1, "behind": 0, "has_upstream": true,
                        "base_ahead": 4, "base_behind": 2,
                        "issue_number": 29, "pr_number": 42,
                        "issue_url": "https://example.test/issues/29",
                        "pr_url": "https://example.test/pull/42",
                        "checks": ["passing": 2, "failing": 0, "cancelled": 0,
                                   "skipped": 0, "pending": 1, "summary": "2 successfull checks"]],
                "terminals": [[
                    "id": sessionId.uuidString, "session_id": "s1", "label": "shell",
                    "kind": "claude", "run_state": "running", "needs_attention": true,
                    "job_name": "vim", "project_id": wsId.uuidString, "project_name": "demo",
                ]],
            ]],
        ])

        let workspaces = try #require(RemoteSnapshotDecoder.decode(snapshotText: text))
        #expect(workspaces.count == 1)
        let workspace = try #require(workspaces.first)
        #expect(workspace.id == wsId)
        #expect(workspace.name == "demo")

        let session = try #require(workspace.sessions.first)
        #expect(session.id == sessionId)
        #expect(session.sessionId == "s1")
        #expect(session.label == "shell")
        #expect(session.kind == .claude)
        #expect(session.isRunning)
        #expect(session.needsAttention)
        #expect(session.jobName == "vim")

        let git = try #require(workspace.git)
        #expect(git.branch == "main")
        #expect(git.ahead == 1)
        #expect(git.behind == 0)
        #expect(git.hasUpstream)
        #expect(git.base == RemoteBase(ahead: 4, behind: 2))
        #expect(git.issueNumber == 29)
        #expect(git.prNumber == 42)
        #expect(git.issueURL == URL(string: "https://example.test/issues/29"))
        #expect(git.prURL == URL(string: "https://example.test/pull/42"))
        #expect(git.checks?.pending == 1)
        #expect(git.checks?.summary == "2 successfull checks")
    }

    @Test func garbageDecodesToNilRatherThanAnEmptyList() {
        #expect(RemoteSnapshotDecoder.decode(snapshotText: "not json") == nil)
    }

    @Test func aValidSnapshotWithNoWorkspacesDecodesToAnEmptyList() throws {
        let workspaces = try #require(
            RemoteSnapshotDecoder.decode(snapshotText: snapshot(["type": "snapshot", "workspaces": []]))
        )
        #expect(workspaces.isEmpty)
    }

    /// A snapshot missing the `workspaces` key entirely is a different situation from
    /// one that has it present as `[]`: the latter is an instance truthfully reporting
    /// it has zero workspaces, but the former is missing the field that defines what
    /// the envelope even is, so it must decode to `nil`, not an empty array. Task 7's
    /// store relies on `nil` vs `[]` to distinguish "haven't heard from the server" from
    /// "the server says there's nothing here," and only marks a connection connected in
    /// the second case. If a future change defaulted `workspaces` to `[]` to be more
    /// "lenient," this test is what would catch that regression.
    @Test func aSnapshotMissingTheWorkspacesKeyEntirelyDecodesToNilNotAnEmptyList() {
        #expect(RemoteSnapshotDecoder.decode(snapshotText: snapshot(["type": "snapshot"])) == nil)
    }

    @Test func aWorkspaceMissingItsIdIsSkipped() throws {
        let good = UUID()
        let text = snapshot(["workspaces": [
            ["name": "no-id"],
            ["id": good.uuidString, "name": "good"],
        ]])
        let workspaces = try #require(RemoteSnapshotDecoder.decode(snapshotText: text))
        #expect(workspaces.map(\.id) == [good])
    }

    @Test func aWorkspaceMissingItsNameIsSkipped() throws {
        let text = snapshot(["workspaces": [["id": UUID().uuidString]]])
        #expect(try #require(RemoteSnapshotDecoder.decode(snapshotText: text)).isEmpty)
    }

    @Test func aWorkspaceWithAnInvalidUUIDIsSkipped() throws {
        let text = snapshot(["workspaces": [["id": "not-a-uuid", "name": "bad"]]])
        #expect(try #require(RemoteSnapshotDecoder.decode(snapshotText: text)).isEmpty)
    }

    @Test func aSessionMissingItsSessionIdIsSkippedButTheWorkspaceSurvives() throws {
        let text = snapshot(["workspaces": [[
            "id": UUID().uuidString, "name": "demo",
            "terminals": [["id": UUID().uuidString, "label": "shell"]],
        ]]])
        let workspaces = try #require(RemoteSnapshotDecoder.decode(snapshotText: text))
        #expect(workspaces.count == 1)
        #expect(workspaces[0].sessions.isEmpty)
    }

    @Test func aSessionWithAnInvalidUUIDIsSkipped() throws {
        let text = snapshot(["workspaces": [[
            "id": UUID().uuidString, "name": "demo",
            "terminals": [["id": "not-a-uuid", "session_id": "s1", "label": "shell"]],
        ]]])
        let workspaces = try #require(RemoteSnapshotDecoder.decode(snapshotText: text))
        #expect(workspaces[0].sessions.isEmpty)
    }

    @Test func everyOptionalFieldMayBeAbsent() throws {
        let text = snapshot(["workspaces": [[
            "id": UUID().uuidString, "name": "demo",
        ]]])
        let workspaces = try #require(RemoteSnapshotDecoder.decode(snapshotText: text))
        let workspace = try #require(workspaces.first)
        #expect(workspace.sessions.isEmpty)
        #expect(workspace.git == nil)
    }

    @Test func aMissingRunStateMeansNotRunning() throws {
        let text = snapshot(["workspaces": [[
            "id": UUID().uuidString, "name": "demo",
            "terminals": [["id": UUID().uuidString, "session_id": "s1", "label": "shell"]],
        ]]])
        let workspaces = try #require(RemoteSnapshotDecoder.decode(snapshotText: text))
        #expect(workspaces[0].sessions[0].isRunning == false)
    }

    @Test func anUnknownKindFallsBackToTerminal() throws {
        let text = snapshot(["workspaces": [[
            "id": UUID().uuidString, "name": "demo",
            "terminals": [["id": UUID().uuidString, "session_id": "s1", "label": "shell",
                           "kind": "not-a-kind"]],
        ]]])
        let workspaces = try #require(RemoteSnapshotDecoder.decode(snapshotText: text))
        #expect(workspaces[0].sessions[0].kind == .terminal)
    }

    @Test func baseAheadWithoutBaseBehindLeavesBaseNil() throws {
        let text = snapshot(["workspaces": [[
            "id": UUID().uuidString, "name": "demo",
            "git": ["branch": "main", "ahead": 0, "behind": 0, "has_upstream": false, "base_ahead": 4],
        ]]])
        let workspaces = try #require(RemoteSnapshotDecoder.decode(snapshotText: text))
        #expect(workspaces[0].git?.base == nil)
    }

    @Test func aMalformedIssueURLBecomesNilWithoutDroppingTheWorkspace() throws {
        let text = snapshot(["workspaces": [[
            "id": UUID().uuidString, "name": "demo",
            "git": ["branch": "main", "ahead": 0, "behind": 0, "has_upstream": false,
                    "issue_url": ""],
        ]]])
        let workspaces = try #require(RemoteSnapshotDecoder.decode(snapshotText: text))
        #expect(workspaces.count == 1)
        #expect(workspaces[0].git?.issueURL == nil)
    }
}
