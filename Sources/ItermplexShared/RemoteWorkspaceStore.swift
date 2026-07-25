import Foundation
import Combine

public enum RemoteConnectionState: Equatable, Sendable {
    case connecting
    case connected
    case unauthorized
    case unreachable
}

/// One remote instance's live state. Holds the `/control` socket open for as long as the
/// connection exists, applies every pushed snapshot wholesale, and posts actions over
/// REST.
@MainActor
public final class RemoteWorkspaceStore: ObservableObject {
    public let connection: RemoteConnection
    @Published public private(set) var state: RemoteConnectionState = .connecting
    @Published public private(set) var workspaces: [RemoteWorkspace] = []
    /// Set when the most recent action POST failed (non 2xx, or a transport error);
    /// cleared as soon as an action succeeds.
    @Published public private(set) var lastActionError: String?

    private let endpoints: RemoteEndpoints
    private var socket: URLSessionWebSocketTask?
    private var running = false
    private var reconnectTask: Task<Void, Never>?

    public init(connection: RemoteConnection) {
        self.connection = connection
        self.endpoints = RemoteEndpoints(connection)
    }

    public func start() {
        guard !running else { return }
        running = true
        connect()
    }

    public func stop() {
        running = false
        reconnectTask?.cancel()
        reconnectTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    /// Pure application of one snapshot message. Marks the connection connected on any
    /// snapshot that decodes, including an empty one. A message that does not decode is
    /// ignored outright: it neither clears the workspaces nor claims a connection.
    public func apply(snapshotText: String) {
        guard let decoded = RemoteSnapshotDecoder.decode(snapshotText: snapshotText) else { return }
        workspaces = decoded
        state = .connected
    }

    private func connect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        guard running, let url = endpoints.control else { return }
        state = .connecting
        let task = URLSession.shared.webSocketTask(with: url)
        socket = task
        task.resume()
        receive()
    }

    private func receive() {
        let task = socket
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.running, task === self.socket else { return }
                switch result {
                case let .success(.string(text)):
                    self.apply(snapshotText: text)
                    self.receive()
                case .success:
                    self.receive()
                case .failure:
                    self.handleDrop()
                }
            }
        }
    }

    /// Pure decision of what state a dropped connection lands in, given the status of
    /// `GET /api/workspaces`.
    ///
    /// The WebSocket handshake cannot answer this question: Hummingbird returns 405
    /// Method Not Allowed when its `shouldUpgrade` closure refuses, so a rejected token
    /// and a broken route are indistinguishable there. The REST route returns a real
    /// 401, which is the only reliable signal that the token is wrong. Anything else,
    /// including no response at all, is a transient failure worth retrying.
    public static func connectionState(forProbeStatus status: Int?) -> RemoteConnectionState {
        status == 401 ? .unauthorized : .unreachable
    }

    private func handleDrop() {
        socket = nil
        guard running else { return }
        reconnectTask = Task { @MainActor in
            let status = await Self.probeStatus(url: self.endpoints.workspaces)
            guard !Task.isCancelled, self.running else { return }
            let newState = Self.connectionState(forProbeStatus: status)
            self.state = newState
            // A bad token will not fix itself, so retrying would spin forever. Only a
            // transient failure gets another attempt.
            guard newState == .unreachable else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, self.running else { return }
            self.connect()
        }
    }

    /// The HTTP status of a token gated GET, or nil when the host could not be reached.
    private static func probeStatus(url: URL?) async -> Int? {
        guard let url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return nil }
        return (response as? HTTPURLResponse)?.statusCode
    }

    // MARK: - Actions
    //
    // Fire and forget as far as the UI is concerned: the next pushed snapshot reconciles
    // state, usually within a few hundred milliseconds. Failures are not swallowed
    // though; they land in `lastActionError` for the UI to show.

    public func openTerminal(workspaceId: UUID) { post(endpoints.openTerminal(workspaceId: workspaceId)) }
    public func openClaude(workspaceId: UUID) { post(endpoints.openClaude(workspaceId: workspaceId)) }
    public func restart(sessionId: String) { post(endpoints.restart(sessionId: sessionId)) }
    public func close(sessionId: String) { post(endpoints.close(sessionId: sessionId)) }

    /// Pure mapping from a POST outcome to a short, user facing message. `nil` means the
    /// action succeeded.
    public static func actionErrorMessage(status: Int?, hadTransportError: Bool) -> String? {
        if hadTransportError { return "Action failed: could not reach the remote." }
        guard let status else { return "Action failed: could not reach the remote." }
        guard (200...299).contains(status) else { return "Action failed (\(status))." }
        return nil
    }

    private func post(_ url: URL?) {
        guard let url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode
            let message = Self.actionErrorMessage(status: status, hadTransportError: error != nil)
            Task { @MainActor in
                self?.lastActionError = message
            }
        }.resume()
    }
}
