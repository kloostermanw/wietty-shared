import Foundation

/// Decodes a `/control` snapshot into `RemoteWorkspace` values.
///
/// Returns `nil` only when the envelope itself cannot be decoded. That is different
/// from returning an empty array, which is a perfectly good snapshot describing an
/// instance with no workspaces, and `RemoteWorkspaceStore` relies on the difference to
/// decide whether it has actually heard from the server.
public enum RemoteSnapshotDecoder {
    public static func decode(snapshotText text: String) -> [RemoteWorkspace]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return decode(data: data)
    }

    public static func decode(data: Data) -> [RemoteWorkspace]? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let snapshot = try? decoder.decode(ControlSnapshot.self, from: data) else { return nil }

        return snapshot.workspaces.compactMap(\.base).map { payload in
            RemoteWorkspace(
                id: payload.id,
                name: payload.name,
                sessions: (payload.terminals ?? []).compactMap(\.base).map(session),
                git: payload.git.map(git)
            )
        }
    }

    private static func session(from payload: TerminalPayload) -> RemoteSession {
        RemoteSession(
            id: payload.id,
            sessionId: payload.sessionId,
            label: payload.label,
            kind: RemoteSessionKind(rawValue: payload.kind ?? "terminal") ?? .terminal,
            isRunning: payload.runState == "running",
            needsAttention: payload.needsAttention == true,
            jobName: payload.jobName
        )
    }

    private static func git(from payload: GitPayload) -> RemoteGit {
        var base: RemoteBase?
        // The server emits both or neither, so anything else is treated as absent.
        if let ahead = payload.baseAhead, let behind = payload.baseBehind {
            base = RemoteBase(ahead: ahead, behind: behind)
        }
        return RemoteGit(
            branch: payload.branch ?? "",
            ahead: payload.ahead ?? 0,
            behind: payload.behind ?? 0,
            hasUpstream: payload.hasUpstream ?? false,
            base: base,
            issueNumber: payload.issueNumber,
            prNumber: payload.prNumber,
            issueURL: payload.issueUrl.flatMap(URL.init(string:)),
            prURL: payload.prUrl.flatMap(URL.init(string:)),
            checks: payload.checks.map(checks)
        )
    }

    private static func checks(from payload: ChecksPayload) -> RemoteChecks {
        RemoteChecks(
            passing: payload.passing ?? 0,
            failing: payload.failing ?? 0,
            cancelled: payload.cancelled ?? 0,
            skipped: payload.skipped ?? 0,
            pending: payload.pending ?? 0,
            summary: payload.summary ?? ""
        )
    }
}
