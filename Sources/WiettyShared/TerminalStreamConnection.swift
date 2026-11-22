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

/// The four calls the connection makes on its socket. `URLSessionWebSocketTask` is the
/// only one in production; the tests hand in a fake so the receive loop can be driven
/// without a server.
protocol WebSocketTransport: AnyObject, Sendable {
    func resume()
    func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, any Error>) -> Void)
    func send(_ message: URLSessionWebSocketTask.Message,
              completionHandler: @escaping @Sendable ((any Error)?) -> Void)
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

extension URLSessionWebSocketTask: WebSocketTransport {}

/// One session's `WS /attach` stream, speaking protocol version 2, bound to no actor.
///
/// Frames arrive from URLSession on a queue of its choosing. They are decoded there and
/// delivered, in the order the server sent them and one at a time, on `callbackQueue`.
/// The queue may be concurrent: any queue but the main one is wrapped in a private serial
/// queue that targets it, so the order holds whatever the caller hands in.
///
/// The first message must be a `hello` carrying `StreamProtocol.version`. It is consumed
/// here and never delivered. A hello with a higher version is a newer server, and ends
/// the stream with `.refused(code: "protocol", ...)` asking for an update. A first
/// message that is anything else (a lower version, or a version 1 server opening with a
/// resize or a data message) ends it with `.serverTooOld`, except an `error`, which ends
/// it with `.refused`: a server that speaks no version 2 at all says so with `error`, and
/// its message is more use to the user than a guess about its age.
///
/// After the hello, a frame this client cannot decode is skipped, which is how a newer
/// server says something this client does not need. `error` and `ended` are not
/// delivered through `onMessage`: they end the stream, through `onEnded`, as `.refused`
/// and `.sessionEnded`.
///
/// `send` and `claim` write nothing until the server's hello has been accepted, and
/// nothing after the stream has ended or been stopped. They are dropped, not queued.
///
/// `onEnded` fires at most once per `start()`, and never because the owner called
/// `stop()`. A failed send ends the stream as `.connectionLost`, through the same single
/// end. `stop()` drops every delivery still waiting on the callback queue. When `stop()`
/// is called on that queue (from inside a callback, or on the main queue when that is the
/// callback queue, or on the caller's own serial queue), nothing is delivered after it
/// returns. Called from any other thread, at most one callback that had already passed
/// its check when `stop()` ran may still run after `stop()` returns.
///
/// Set `onMessage` and `onEnded` before `start()`. They are read on `callbackQueue`
/// without a lock, so setting them while a stream runs is a data race.
///
/// The receive loop is bound to the socket instance it was started for (`task ===
/// socket`, checked under the lock together with the state it changes), so a `stop()`
/// followed quickly by a new `start()` can never let a stale loop deliver into the new
/// stream or keep looping after teardown. The socket sits behind `WebSocketTransport`,
/// so the tests drive that loop with a fake; only `URLSessionWebSocketTask` itself is
/// left to a live server.
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
    private let makeTransport: @Sendable (URL) -> any WebSocketTransport

    private let lock = NSLock()
    // Guarded by `lock`.
    private var socket: (any WebSocketTransport)?
    private var phase = Phase.awaitingHello
    /// Bumped by every `start()` and `stop()`. A delivery carries the generation it was
    /// decided in and is dropped if that is no longer current.
    private var generation: UInt64 = 0

    /// Every message after the server's hello, in order, on `callbackQueue`.
    public var onMessage: (@Sendable (StreamMessage) -> Void)?
    /// Why the stream ended, on `callbackQueue`. At most once per `start()`.
    public var onEnded: (@Sendable (TerminalEndReason) -> Void)?

    public convenience init(connection: RemoteConnection, sessionId: String, resize: ResizeMode,
                            callbackQueue: DispatchQueue) {
        self.init(connection: connection, sessionId: sessionId, resize: resize,
                  callbackQueue: callbackQueue,
                  transport: { URLSession.shared.webSocketTask(with: $0) })
    }

    /// Internal: `transport` makes the socket for a URL, so the tests can hand in a fake.
    init(connection: RemoteConnection, sessionId: String, resize: ResizeMode,
         callbackQueue: DispatchQueue,
         transport: @escaping @Sendable (URL) -> any WebSocketTransport) {
        self.makeTransport = transport
        self.endpoints = RemoteEndpoints(connection)
        self.sessionId = sessionId
        self.resize = resize
        // The main queue is serial already, and it is kept as it is: the main actor
        // wrapper relies on `MainActor.assumeIsolated`, which holds only on the main queue
        // itself, not on a queue that merely targets it.
        self.callbackQueue = callbackQueue === DispatchQueue.main
            ? callbackQueue
            : DispatchQueue(label: "wietty.terminal-stream.callbacks", target: callbackQueue)
    }

    deinit {
        socket?.cancel(with: .goingAway, reason: nil)
    }

    /// Opens the socket. Does nothing while a socket is already open.
    ///
    /// A new start drops an `onEnded` of the previous one that was still waiting on the
    /// callback queue. An owner that reconnects should therefore do so from `onEnded`,
    /// not blindly, or it never hears why the previous stream ended.
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
        let task = makeTransport(url)
        socket = task
        lock.unlock()
        task.resume()
        receive(on: task)
    }

    /// Closes the socket. Fires no `onEnded`, and drops whatever is still waiting to be
    /// delivered. Called on the callback queue, nothing is delivered after it returns;
    /// called from another thread, at most one callback already past its check may still
    /// run. See the type's doc comment.
    public func stop() {
        lock.lock()
        generation &+= 1
        phase = .finished
        let task = socket
        socket = nil
        lock.unlock()
        task?.cancel(with: .goingAway, reason: nil)
    }

    /// Input for the remote terminal, byte exact. Dropped before the server's hello and
    /// after an end.
    public func send(_ bytes: [UInt8]) {
        write(.data(bytes))
    }

    /// Claims the grid at this size. `own` means nothing upstream and is sent as false.
    /// Dropped before the server's hello and after an end.
    public func claim(cols: Int, rows: Int) {
        write(.resize(cols: cols, rows: rows, own: false))
    }

    private func write(_ message: StreamMessage) {
        let current: (any WebSocketTransport)? = lock.withLock {
            phase == .streaming ? socket : nil
        }
        guard let task = current else { return }
        let frame: URLSessionWebSocketTask.Message
        switch StreamCodec.webSocketFrame(for: message) {
        case .text(let text): frame = .string(text)
        case .binary(let bytes): frame = .data(Data(bytes))
        }
        task.send(frame) { [weak self] error in
            if error != nil { self?.end(.connectionLost, from: task) }
        }
    }

    private func receive(on task: any WebSocketTransport) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text): self.process(.text(text), from: task)
                case .data(let data): self.process(.binary(Array(data)), from: task)
                @unknown default: break   // a kind of frame this client cannot read: skipped
                }
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
    private func process(_ frame: StreamCodec.WebSocketFrame, from task: (any WebSocketTransport)?) {
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
        case (.awaitingHello, .hello(let version, _, _)) where version > StreamProtocol.version:
            lock.unlock()
            end(.refused(code: "protocol",
                         message: "This Mac runs a newer Wietty. Update Wietty on this device."),
                from: task)
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
    private func end(_ reason: TerminalEndReason, from task: (any WebSocketTransport)?) {
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
    /// in between. Deliveries are queued in the server's order, and `callbackQueue` is
    /// serial (see `init`), so they run in that order and one at a time.
    ///
    /// The generation is checked under the lock and `body` runs after it is released, so
    /// a `stop()` on another thread can land between the two. Holding the lock across
    /// `body` would close that gap but deadlock a callback that calls `stop()` or `send`.
    private func deliver(in generation: UInt64,
                         _ body: @escaping @Sendable (TerminalStreamConnection) -> Void) {
        callbackQueue.async { [weak self] in
            guard let self, self.lock.withLock({ self.generation == generation }) else { return }
            body(self)
        }
    }
}
