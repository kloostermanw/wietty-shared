import Foundation

/// Bridges one remote session's `WS /attach` stream to a byte feed for a terminal view
/// and an input sink back to the server.
///
/// The receive loop is bound to the specific socket instance it was started for (via
/// `task === self.socket`), so a `stop()` followed quickly by a new `start()` can never
/// let a stale receive loop deliver into the new socket or keep looping after teardown.
@MainActor
public final class RemoteTerminalConnection {
    private let endpoints: RemoteEndpoints
    private let sessionId: String
    private var socket: URLSessionWebSocketTask?
    private var running = false

    /// Decoded VT bytes to feed the terminal.
    public var onData: (([UInt8]) -> Void)?
    /// The remote grid size, as (cols, rows).
    public var onResize: ((Int, Int) -> Void)?
    /// The session ended, or the socket failed. Terminal in both cases.
    public var onEnded: (() -> Void)?

    public init(connection: RemoteConnection, sessionId: String) {
        self.endpoints = RemoteEndpoints(connection)
        self.sessionId = sessionId
    }

    public func start() {
        guard !running, let url = endpoints.attach(sessionId: sessionId) else { return }
        running = true
        let task = URLSession.shared.webSocketTask(with: url)
        socket = task
        task.resume()
        receive(on: task)
    }

    public func stop() {
        running = false
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    /// Forwards keystroke bytes from the terminal view up to the server.
    public func send(_ bytes: ArraySlice<UInt8>) {
        guard running, let json = AttachMessage.encodeInput(bytes) else { return }
        socket?.send(.string(json)) { _ in }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.running, task === self.socket else { return }
                switch result {
                case let .success(.string(text)):
                    self.handle(text)
                    self.receive(on: task)
                case .success:
                    self.receive(on: task)
                case .failure:
                    self.stop()
                    self.onEnded?()
                }
            }
        }
    }

    /// Internal rather than private so the tests can drive one message at a time
    /// without a live server.
    func handle(_ text: String) {
        switch AttachMessage.parse(text) {
        case let .resize(cols, rows):
            onResize?(cols, rows)
        case let .data(bytes):
            onData?(bytes)
        case .ended:
            stop()
            onEnded?()
        case nil:
            break
        }
    }
}
