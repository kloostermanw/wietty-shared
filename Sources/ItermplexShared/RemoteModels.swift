import Foundation

/// What a remote session is running. Mirrors the server's `kind` field.
public enum RemoteSessionKind: String, Codable, Sendable {
    case terminal
    case claude
}

/// One iTerm2 session on a remote instance.
public struct RemoteSession: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var sessionId: String
    public var label: String
    public var kind: RemoteSessionKind
    /// Decoded from `run_state == "running"`. Only meaningful for `.claude` sessions,
    /// which is how the macOS UI treats it.
    public var isRunning: Bool
    public var needsAttention: Bool
    public var jobName: String?

    public init(id: UUID, sessionId: String, label: String, kind: RemoteSessionKind = .terminal,
                isRunning: Bool = false, needsAttention: Bool = false, jobName: String? = nil) {
        self.id = id
        self.sessionId = sessionId
        self.label = label
        self.kind = kind
        self.isRunning = isRunning
        self.needsAttention = needsAttention
        self.jobName = jobName
    }
}

/// Divergence from the base branch. The server emits `base_ahead` and `base_behind`
/// together or not at all, so an optional struct expresses the rule the wire format
/// already follows instead of leaving it to a separate `hasBase` flag.
public struct RemoteBase: Equatable, Sendable {
    public var ahead: Int
    public var behind: Int

    public init(ahead: Int, behind: Int) {
        self.ahead = ahead
        self.behind = behind
    }
}

/// Three way outcome of a `RemoteChecks`.
public enum RemoteChecksStatus: Equatable, Sendable {
    case failed
    case running
    case passed
}

public struct RemoteChecks: Equatable, Sendable {
    public var passing: Int
    public var failing: Int
    public var cancelled: Int
    public var skipped: Int
    public var pending: Int
    /// Human readable line built by the server, displayed as is.
    public var summary: String

    public init(passing: Int, failing: Int, cancelled: Int, skipped: Int, pending: Int, summary: String) {
        self.passing = passing
        self.failing = failing
        self.cancelled = cancelled
        self.skipped = skipped
        self.pending = pending
        self.summary = summary
    }

    public var total: Int { passing + failing + cancelled + skipped + pending }
    public var hasFailures: Bool { failing + cancelled > 0 }

    /// Failures win over pending, which wins over success.
    public var status: RemoteChecksStatus {
        if hasFailures { return .failed }
        if pending > 0 { return .running }
        return .passed
    }
}

public struct RemoteGit: Equatable, Sendable {
    public var branch: String
    public var ahead: Int
    public var behind: Int
    public var hasUpstream: Bool
    public var base: RemoteBase?
    public var issueNumber: Int?
    public var prNumber: Int?
    public var issueURL: URL?
    public var prURL: URL?
    public var checks: RemoteChecks?

    public init(branch: String, ahead: Int, behind: Int, hasUpstream: Bool,
                base: RemoteBase? = nil, issueNumber: Int? = nil, prNumber: Int? = nil,
                issueURL: URL? = nil, prURL: URL? = nil, checks: RemoteChecks? = nil) {
        self.branch = branch
        self.ahead = ahead
        self.behind = behind
        self.hasUpstream = hasUpstream
        self.base = base
        self.issueNumber = issueNumber
        self.prNumber = prNumber
        self.issueURL = issueURL
        self.prURL = prURL
        self.checks = checks
    }
}

/// One workspace on a remote instance. There is no local folder behind it, which is
/// why this type has no URL: a remote workspace is identified by id and displayed by
/// name, and nothing about it may be resolved against the local filesystem.
public struct RemoteWorkspace: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var sessions: [RemoteSession]
    public var git: RemoteGit?

    public init(id: UUID, name: String, sessions: [RemoteSession] = [], git: RemoteGit? = nil) {
        self.id = id
        self.name = name
        self.sessions = sessions
        self.git = git
    }
}
