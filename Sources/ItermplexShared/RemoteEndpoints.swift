import Foundation

/// Every URL one remote instance exposes. Pure and string based, so the exact query
/// shape the server matches on (`?token=`, `&session=`) is pinned by tests instead of
/// being discovered at runtime against a live Mac.
///
/// The surrounding shape is still built by string interpolation rather than
/// `URLComponents`, because `URLComponents` would change the byte-identical URLs the
/// server matches on. Every *value* interpolated into that shape (`token`, `sessionId`)
/// is percent-encoded first through `urlSafe(_:)`, so only the value's bytes change, not
/// the surrounding structure.
///
/// An earlier version of this comment argued no encoding was needed at all: a token is
/// 32 lowercase hexadecimal characters, and `sessionId` was an iTerm2 GUID, so neither
/// needed escaping and a stray character would at worst degrade to a clean 401. That
/// argument depended on `sessionId` staying GUID-shaped, and stopped being true when the
/// macOS app migrated session identifiers to tmux pane ids such as `%12`. `%` is the
/// percent-encoding escape character, so `URL(string:)` parsed `%12` as an escaped
/// `U+0012` control character rather than the literal pane id, and the server received a
/// session id that named no pane, not a 401. Pane ids `%0` through `%9` happened to
/// survive by accident (`%3` re-encodes to `%253`, which decodes back to `%3`), so the
/// failure stayed invisible until a long-lived tmux server's pane count passed nine.
/// `CharacterSet.urlQueryAllowed` and `.urlPathAllowed` are not sufficient replacements:
/// both permit characters (`&`, `=`, `/`) that are structural in a single query value or
/// path segment, so `urlSafe(_:)` restricts encoding to RFC 3986's unreserved set.
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

    public var control: URL? { URL(string: "\(wsBase)/control?token=\(Self.urlSafe(token))") }

    public func attach(sessionId: String) -> URL? {
        URL(string: "\(wsBase)/attach?session=\(Self.urlSafe(sessionId))&token=\(Self.urlSafe(token))")
    }

    public var workspaces: URL? { api("api/workspaces") }

    public func openTerminal(workspaceId: UUID) -> URL? {
        api("api/workspaces/\(workspaceId.uuidString)/terminal")
    }

    public func openClaude(workspaceId: UUID) -> URL? {
        api("api/workspaces/\(workspaceId.uuidString)/claude")
    }

    public func restart(sessionId: String) -> URL? {
        api("api/sessions/\(Self.urlSafe(sessionId))/restart")
    }

    public func close(sessionId: String) -> URL? {
        api("api/sessions/\(Self.urlSafe(sessionId))/close")
    }

    private func api(_ path: String) -> URL? {
        URL(string: "\(httpBase)/\(path)?token=\(Self.urlSafe(token))")
    }

    /// Percent-encodes a raw value for safe interpolation into a single path segment or
    /// query value. Restricted to RFC 3986's unreserved characters (letters, digits,
    /// `-`, `.`, `_`, `~`) rather than `CharacterSet.urlQueryAllowed`/`.urlPathAllowed`,
    /// because those two are scoped to an entire query or path, not one value inside it:
    /// `urlQueryAllowed` permits `&` and `=`, which would let a value inject another
    /// query item, and `urlPathAllowed` permits `/`, which would let a value inject
    /// another path segment. `addingPercentEncoding` only returns nil for encodings a
    /// `String` cannot represent, which does not happen here, but the fallback keeps
    /// this helper total rather than trapping on an unreachable case.
    private static func urlSafe(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreservedURLCharacters) ?? value
    }

    private static let unreservedURLCharacters: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}
