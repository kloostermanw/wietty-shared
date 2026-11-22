import Foundation

/// A `TerminalStreamConnection` for a terminal view on the main actor, in repaint mode.
///
/// Every callback runs on the main actor. Snapshot, repaint and data bytes all reach
/// `onData`: a snapshot starts with a hard reset and a repaint redraws the visible
/// screen, so a terminal that is simply fed them in order ends up right. See
/// `TerminalStreamConnection` for the handshake and the end reasons. `onEnded` fires at
/// most once per `start()`. Because `stop()` runs on the main actor, which is this
/// stream's callback queue, nothing at all is delivered after `stop()` returns.
@MainActor
public final class RemoteTerminalConnection {
    /// Internal so the tests can feed frames without a live server.
    let stream: TerminalStreamConnection

    /// Bytes to feed the terminal, in the order the server sent them.
    public var onData: (([UInt8]) -> Void)?
    /// The grid in force, as (cols, rows, own), where `own` says this viewer claimed it.
    public var onResize: ((Int, Int, Bool) -> Void)?
    /// The stream stopped for a reason of its own. Not fired by `stop()`.
    public var onEnded: ((TerminalEndReason) -> Void)?

    public init(connection: RemoteConnection, sessionId: String) {
        stream = TerminalStreamConnection(connection: connection, sessionId: sessionId,
                                          resize: .repaint, callbackQueue: .main)
        stream.onMessage = { [weak self] message in
            MainActor.assumeIsolated { self?.receive(message) }
        }
        stream.onEnded = { [weak self] reason in
            MainActor.assumeIsolated { self?.onEnded?(reason) }
        }
    }

    public func start() {
        stream.start()
    }

    public func stop() {
        stream.stop()
    }

    /// Forwards keystroke bytes from the terminal view up to the server.
    public func send(_ bytes: ArraySlice<UInt8>) {
        stream.send(Array(bytes))
    }

    /// Claims the grid at this size.
    public func claim(cols: Int, rows: Int) {
        stream.claim(cols: cols, rows: rows)
    }

    private func receive(_ message: StreamMessage) {
        switch message {
        case let .resize(cols, rows, own):
            onResize?(cols, rows, own)
        case let .snapshot(bytes), let .repaint(bytes), let .data(bytes):
            onData?(bytes)
        case .hello, .error, .ended:
            // Never delivered by the stream: it consumes the hello and turns the other two
            // into `onEnded`.
            break
        }
    }
}
