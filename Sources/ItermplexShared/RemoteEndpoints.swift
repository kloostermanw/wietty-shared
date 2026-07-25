import Foundation

/// Every URL one remote instance exposes. Pure and string based, so the exact query
/// shape the server matches on (`?token=`, `&session=`) is pinned by tests instead of
/// being discovered at runtime against a live Mac.
public struct RemoteEndpoints: Equatable, Sendable {
    private let host: String
    private let port: Int
    private let token: String

    public init(host: String, port: Int, token: String) {
        self.host = host
        self.port = port
        self.token = token
    }

    public init(_ connection: RemoteConnection) {
        self.init(host: connection.host, port: connection.port, token: connection.token)
    }

    private var httpBase: String { "http://\(host):\(port)" }
    private var wsBase: String { "ws://\(host):\(port)" }

    public var control: URL? { URL(string: "\(wsBase)/control?token=\(token)") }

    public func attach(sessionId: String) -> URL? {
        URL(string: "\(wsBase)/attach?session=\(sessionId)&token=\(token)")
    }

    public var workspaces: URL? { api("api/workspaces") }

    public func openTerminal(workspaceId: UUID) -> URL? {
        api("api/workspaces/\(workspaceId.uuidString)/terminal")
    }

    public func openClaude(workspaceId: UUID) -> URL? {
        api("api/workspaces/\(workspaceId.uuidString)/claude")
    }

    public func restart(sessionId: String) -> URL? {
        api("api/sessions/\(sessionId)/restart")
    }

    public func close(sessionId: String) -> URL? {
        api("api/sessions/\(sessionId)/close")
    }

    private func api(_ path: String) -> URL? {
        URL(string: "\(httpBase)/\(path)?token=\(token)")
    }
}
