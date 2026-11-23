import Foundation

/// The version of the terminal stream protocol this package speaks.
public enum StreamProtocol {
    public static let version = 2
    /// The largest message the protocol carries, on either transport. A snapshot is one
    /// message, about 11 MB at 100,000 lines of history, so this is well above that.
    public static let maxMessageSize = 64 << 20
}

/// What a viewer wants after the grid changes.
public enum ResizeMode: String, Sendable, Equatable {
    /// The viewer reflows by itself. It is sent the new grid and nothing else.
    case reflow
    /// The viewer is sent the visible screen again.
    case repaint
}

/// One message on a terminal stream, in either direction, on either transport.
public enum StreamMessage: Equatable, Sendable {
    /// First message. A viewer on the Unix socket names its session and resize mode;
    /// the server's answer carries the version only.
    case hello(protocolVersion: Int, session: String?, resize: ResizeMode?)
    /// The server refuses, and closes after this.
    case error(code: String, message: String)
    /// Server to viewer: the grid in force, and whether this viewer claimed it.
    /// Viewer to server: a claim, where `own` means nothing and is sent as false.
    case resize(cols: Int, rows: Int, own: Bool)
    /// A hard reset, then history and screen. Replaces everything the viewer holds.
    case snapshot([UInt8])
    /// The visible screen again. History is untouched.
    case repaint([UInt8])
    /// Server to viewer: the child's output. Viewer to server: input. Byte exact.
    case data([UInt8])
    /// The terminal has stopped.
    case ended
}
