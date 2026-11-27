import Foundation

/// Every URL one remote instance exposes. Pure and string based, so the exact query
/// shape the server matches on (`?token=`, `&session=`) is pinned by tests instead of
/// being discovered at runtime against a live Mac.
///
/// The surrounding shape is still built by string interpolation rather than
/// `URLComponents`, because `URLComponents` would change the byte-identical URLs the
/// server matches on. Every query *value* interpolated into that shape (`token`, and
/// `sessionId` in `attach`) is percent-encoded first through `queryEncoded(_:)`, so only
/// the value's bytes change, not the surrounding structure.
///
/// An earlier version of this comment argued no encoding was needed anywhere: a token is
/// 32 lowercase hexadecimal characters, and `sessionId` was an iTerm2 GUID, so neither
/// needed escaping and a stray character would at worst degrade to a clean 401. That
/// argument depended on `sessionId` staying GUID-shaped, and stopped being true when the
/// macOS app, for a time, used tmux pane ids such as `%12` as session identifiers. `%` is the
/// percent-encoding escape character, so `URL(string:)` parsed `%12` as an escaped
/// `U+0012` control character rather than the literal pane id, and the server's query
/// decoder (`URI.queryParameters`, which calls `percentDecode()` on every value) turned
/// it into that same control byte again, so the server received a session id that named
/// no pane, not a 401. Pane ids `%0` through `%9` happened to survive by accident (`%3`
/// re-encodes to `%253`, which decodes back to `%3`), so the failure stayed invisible
/// until a long-lived tmux server's pane count passed nine.
///
/// Neither shape is in use any more: a session id is now `gt:` followed by a lowercase
/// UUID, minted by the macOS app's own terminal. The encoding stays, because the `:` in
/// it is not in the unreserved set either (it goes out as `%3A` and the server decodes
/// it), and because nothing here should depend on the id's shape again.
///
/// `sessionId` in `stop(sessionId:)`, `restart(sessionId:)` and `close(sessionId:)` is
/// deliberately left unencoded, unlike `attach`'s query value, because those put `sessionId` in a
/// *path* segment, and the server's router (`Trie+resolve.swift`'s `.capture` case)
/// stores the raw path component verbatim with no decoding step; `percentDecode()` is
/// called nowhere in that path. Encoding it here with no matching decode on the other
/// end would turn `%12` into `%2512` on the wire (and the `:` of today's ids into `%3A`)
/// and permanently break the match, since the server compares the parameter against the
/// session id byte for byte. This is safe only because of the id's shape, and the
/// reasoning that held for tmux pane ids (`%` followed by digits) holds for `gt:` plus a
/// UUID as well: letters, digits, `-` and one `:`, never `/`, `?` or `#`, so nothing
/// in a path segment there can inject a spurious segment; if `sessionId`'s shape ever
/// gains a character that is unsafe in a path, `stop`/`restart`/`close` need a coordinated fix
/// on the server (which would then need to decode `:sid` itself) in the same change.
///
/// `CharacterSet.urlQueryAllowed` is not a sufficient replacement for `queryEncoded(_:)`:
/// it permits `&` and `=`, which would let a value inject another query item, so
/// `queryEncoded(_:)` restricts encoding to RFC 3986's unreserved set instead.
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

    public var control: URL? { URL(string: "\(wsBase)/control?token=\(Self.queryEncoded(token))") }

    /// One session's terminal stream, in protocol version `StreamProtocol.version`. The
    /// version and the resize mode are appended after the token, so the part of the URL a
    /// version 1 server matched on is unchanged. A server that finds no `protocol` here
    /// takes the client for a version 1 one.
    public func attach(sessionId: String, resize: ResizeMode) -> URL? {
        URL(string: "\(wsBase)/attach?session=\(Self.queryEncoded(sessionId))"
            + "&token=\(Self.queryEncoded(token))"
            + "&protocol=\(StreamProtocol.version)&resize=\(resize.rawValue)")
    }

    public var workspaces: URL? { api("api/workspaces") }

    public func openTerminal(workspaceId: UUID) -> URL? {
        api("api/workspaces/\(workspaceId.uuidString)/terminal")
    }

    public func openClaude(workspaceId: UUID) -> URL? {
        api("api/workspaces/\(workspaceId.uuidString)/claude")
    }

    /// Makes sure the row with this id has a live session on the serving instance,
    /// opening one when it has none, and answers with the row's terminal JSON.
    ///
    /// Keyed by the row's id rather than its session id, unlike `restart` and `close`.
    /// A row that has never been opened carries an empty session id, and a row whose
    /// serving instance was relaunched carries one that names nothing, so a session id
    /// cannot address the rows this route exists for. A row id is a UUID, so unlike
    /// `restart`/`close`'s pane ids it needs no thought about path safety.
    public func activate(refId: UUID) -> URL? {
        api("api/terminals/\(refId.uuidString)/activate")
    }

    // sessionId is interpolated raw here, not through `queryEncoded(_:)`: see the type's
    // doc comment for why a path segment must not be encoded without a matching decode
    // step on the server.
    public func restart(sessionId: String) -> URL? {
        api("api/sessions/\(sessionId)/restart")
    }

    /// Ends the session's child and keeps its row, which is what tells it from `close`.
    /// A serving instance older than this route answers 404, as it does for a session
    /// no row carries, so a caller cannot tell the two apart from the status.
    public func stop(sessionId: String) -> URL? {
        api("api/sessions/\(sessionId)/stop")
    }

    public func close(sessionId: String) -> URL? {
        api("api/sessions/\(sessionId)/close")
    }

    private func api(_ path: String) -> URL? {
        URL(string: "\(httpBase)/\(path)?token=\(Self.queryEncoded(token))")
    }

    /// Percent-encodes a raw value for safe interpolation into a single query value.
    /// Restricted to RFC 3986's unreserved characters (letters, digits, `-`, `.`, `_`,
    /// `~`) rather than `CharacterSet.urlQueryAllowed`, because `urlQueryAllowed` is
    /// scoped to an entire query, not one value inside it, and permits `&` and `=`,
    /// which would let a value inject another query item. `addingPercentEncoding` only
    /// returns nil for encodings a `String` cannot represent, which does not happen
    /// here, but the fallback keeps this helper total rather than trapping on an
    /// unreachable case.
    private static func queryEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreservedURLCharacters) ?? value
    }

    private static let unreservedURLCharacters: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}
