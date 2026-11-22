import Foundation

/// Why a terminal stream stopped. Terminal in every case; the reason says whether
/// reconnecting could plausibly help.
public enum TerminalEndReason: Equatable, Sendable {
    /// The server reported the session is gone. Reconnecting will not bring it back.
    case sessionEnded
    /// The socket failed, or no URL could be built. The session may still exist.
    case connectionLost
    /// The server answered without a version 2 hello: it is older than this client.
    case serverTooOld
    /// The server refused with `error`.
    case refused(code: String, message: String)
}

/// One session's `WS /attach` stream, speaking protocol version 2, bound to no actor.
///
/// Frames arrive from URLSession on a queue of its choosing. They are decoded there and
/// delivered, in the order the server sent them, on `callbackQueue`, which must be serial
/// for that order to hold.
///
/// The first message must be a `hello` carrying `StreamProtocol.version`. It is consumed
/// here and never delivered. A first message that is anything else (a version 1 server
/// opens with a resize or a data message) ends the stream with `.serverTooOld`, except an
/// `error`, which ends it with `.refused`: a server that speaks no version 2 at all says
/// so with `error`, and its message is more use to the user than a guess about its age.
///
/// After the hello, a frame this client cannot decode is skipped, which is how a newer
/// server says something this client does not need. `error` and `ended` are not
/// delivered through `onMessage`: they end the stream, through `onEnded`, as `.refused`
/// and `.sessionEnded`.
///
/// `onEnded` fires at most once per `start()`, and never because the owner called
/// `stop()`. Once `stop()` returns, nothing more is delivered from that start, not even a
/// message decoded before it and still waiting on `callbackQueue`.
///
/// Set `onMessage` and `onEnded` before `start()`. They are read on `callbackQueue`
/// without a lock, so setting them while a stream runs is a data race.
///
/// The receive loop is bound to the socket instance it was started for (`task ===
/// socket`, checked under the lock together with the state it changes), so a `stop()`
/// followed quickly by a new `start()` can never let a stale loop deliver into the new
/// stream or keep looping after teardown. There is no injection seam over
/// `URLSessionWebSocketTask`, so that loop is verified by inspection and against a live
/// server; everything after a frame has arrived is driven by tests through `handle(_:)`.
public final class TerminalStreamConnection: @unchecked Sendable {
    private enum Phase {
        case awaitingHello
        case streaming
        case finished
    }

    private let endpoints: RemoteEndpoints
    private let sessionId: String
    private let resize: ResizeMode
    private let callbackQueue: DispatchQueue

    private let lock = NSLock()
    // Guarded by `lock`.
    private var socket: URLSessionWebSocketTask?
    private var phase = Phase.awaitingHello
    /// Bumped by every `start()` and `stop()`. A delivery carries the generation it was
    /// decided in and is dropped if that is no longer current.
    private var generation: UInt64 = 0

    /// Every message after the server's hello, in order, on `callbackQueue`.
    public var onMessage: (@Sendable (StreamMessage) -> Void)?
    /// Why the stream ended, on `callbackQueue`. At most once per `start()`.
    public var onEnded: (@Sendable (TerminalEndReason) -> Void)?

    public init(connection: RemoteConnection, sessionId: String, resize: ResizeMode,
                callbackQueue: DispatchQueue) {
        self.endpoints = RemoteEndpoints(connection)
        self.sessionId = sessionId
        self.resize = resize
        self.callbackQueue = callbackQueue
    }

    deinit {
        socket?.cancel(with: .goingAway, reason: nil)
    }

    /// Opens the socket. Does nothing while a socket is already open.
    public func start() {
        lock.lock()
        guard socket == nil else {
            lock.unlock()
            return
        }
        generation &+= 1
        phase = .awaitingHello
        guard let url = endpoints.attach(sessionId: sessionId, resize: resize) else {
            lock.unlock()
            end(.connectionLost, from: nil)
            return
        }
        let task = URLSession.shared.webSocketTask(with: url)
        socket = task
        lock.unlock()
        task.resume()
        receive(on: task)
    }

    /// Closes the socket. Fires no `onEnded`, and drops whatever is still waiting to be
    /// delivered.
    public func stop() {
        lock.lock()
        generation &+= 1
        phase = .finished
        let task = socket
        socket = nil
        lock.unlock()
        task?.cancel(with: .goingAway, reason: nil)
    }

    /// Input for the remote terminal, byte exact.
    public func send(_ bytes: [UInt8]) {
        write(.data(bytes))
    }

    /// Claims the grid at this size. `own` means nothing upstream and is sent as false.
    public func claim(cols: Int, rows: Int) {
        write(.resize(cols: cols, rows: rows, own: false))
    }

    private func write(_ message: StreamMessage) {
        guard let task = lock.withLock({ socket }) else { return }
        let frame: URLSessionWebSocketTask.Message
        switch StreamCodec.webSocketFrame(for: message) {
        case .text(let text): frame = .string(text)
        case .binary(let bytes): frame = .data(Data(bytes))
        }
        // A failed send needs no handling here: the receive loop sees the same failure
        // and ends the stream.
        task.send(frame) { _ in }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                let frame: StreamCodec.WebSocketFrame
                switch message {
                case .string(let text): frame = .text(text)
                case .data(let data): frame = .binary(Array(data))
                @unknown default: frame = .binary([])
                }
                self.process(frame, from: task)
                if self.lock.withLock({ task === self.socket }) {
                    self.receive(on: task)
                }
            case .failure:
                self.end(.connectionLost, from: task)
            }
        }
    }

    /// Internal rather than private so the tests can drive one frame at a time without a
    /// live server.
    func handle(_ frame: StreamCodec.WebSocketFrame) {
        process(frame, from: nil)
    }

    /// `task` is the socket the frame came from, or nil when a test feeds it.
    private func process(_ frame: StreamCodec.WebSocketFrame, from task: URLSessionWebSocketTask?) {
        let message = StreamCodec.message(from: frame)
        lock.lock()
        guard phase != .finished, task == nil || task === socket else {
            lock.unlock()
            return
        }
        switch (phase, message) {
        case (.awaitingHello, .hello(let version, _, _)) where version == StreamProtocol.version:
            phase = .streaming
            lock.unlock()
        case (_, .error(let code, let text)):
            lock.unlock()
            end(.refused(code: code, message: text), from: task)
        case (.awaitingHello, _):
            lock.unlock()
            end(.serverTooOld, from: task)
        case (_, .ended):
            lock.unlock()
            end(.sessionEnded, from: task)
        case (_, nil), (_, .hello):
            lock.unlock()
        case (_, .some(let message)):
            let current = generation
            lock.unlock()
            deliver(in: current) { $0.onMessage?(message) }
        }
    }

    /// Ends the stream for a reason of its own, once. `task` as in `process`.
    private func end(_ reason: TerminalEndReason, from task: URLSessionWebSocketTask?) {
        lock.lock()
        guard phase != .finished, task == nil || task === socket else {
            lock.unlock()
            return
        }
        phase = .finished
        let closing = socket
        socket = nil
        let current = generation
        lock.unlock()
        closing?.cancel(with: .goingAway, reason: nil)
        deliver(in: current) { $0.onEnded?(reason) }
    }

    /// Queues `body` on `callbackQueue`, to run only if no `start()` or `stop()` has come
    /// in between. Every delivery is queued from the one receive loop, one after the
    /// other, so a serial `callbackQueue` keeps the server's order.
    private func deliver(in generation: UInt64,
                         _ body: @escaping @Sendable (TerminalStreamConnection) -> Void) {
        callbackQueue.async { [weak self] in
            guard let self, self.lock.withLock({ self.generation == generation }) else { return }
            body(self)
        }
    }
}
