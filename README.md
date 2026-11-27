# wietty-shared

The platform neutral client for [Wietty](https://github.com/kloostermanw/wietty)'s LAN
remote protocol. Shared by the macOS app (which both serves and consumes the protocol) and the
iPadOS client.

## What is in here

| Type | Responsibility |
| --- | --- |
| `RemoteWorkspace`, `RemoteSession`, `RemoteGit`, `RemoteChecks` | Remote native models, with no local filesystem notion |
| `RemoteSnapshotDecoder` | Decodes a `/control` snapshot into those models, tolerantly |
| `RemoteEndpoints` | Every URL one remote instance exposes |
| `RemoteWorkspaceStore` | One instance's live state: the `/control` socket, plus REST actions |
| `RemoteWorkspacesController` | Maps saved connections to live stores |
| `StreamMessage`, `StreamCodec`, `StreamFrameReader` | The terminal stream's messages (protocol version 2) and their WebSocket and Unix socket framings |
| `TerminalStreamConnection` | One session's `/attach` stream, in both directions, bound to no actor. Accepts messages up to `StreamProtocol.maxMessageSize` (64 MiB) |
| `RemoteTerminalConnection` | The same stream for a terminal view on the main actor, in repaint mode |
| `RemoteConnection`, `RemoteConnectionsStore`, `SecretStore` | Saved connections, with tokens in the Keychain |

The protocol itself is documented in the macOS repo, at `documentation/remote-access.md`.

## Requirements

iOS 16, macOS 14. Nothing outside Foundation, Combine, and Security, so the package builds for
either platform without conditionals.

## Tests

```sh
swift test
```

## SwiftUI note

The observable types conform to `ObservableObject` rather than using the `@Observable` macro,
because the iPadOS client supports iOS 16 and the macro needs iOS 17. Nested `ObservableObject`
changes do not propagate, so render each connection's UI from a subview that observes its own
`RemoteWorkspaceStore`.

## Consuming this package

A few things are easy to get wrong because nothing in the type system enforces them.

- `workspaces` is only meaningful while `state == .connected`. `RemoteWorkspaceStore` does not
  clear the last good snapshot on a drop, so a disconnected store still holds it indefinitely.
  Gate any UI built from `workspaces` on `state`. The obvious implementation, a list bound
  straight to `store.workspaces` with a status badge beside it, would show a dead remote's
  sessions as live forever and let the user tap into an attach socket that ends immediately.
- Call `RemoteWorkspacesController.sync()` once at launch and again after every add, edit, or
  remove of a connection. Nothing enforces this, and a missed call fails silently: a newly added
  connection's section never appears, or an edited connection keeps talking to its old address.
- Attach to the session id `activate(refId:)` returns, not to the one the row already carried.
  A row whose serving instance has no live session for it (never opened, or relaunched since)
  gets a new session, and the id it had before is the dead one. Every other action on the store
  is fire and forget because the next snapshot reconciles it a few hundred milliseconds later;
  a click cannot wait that long without attaching to the wrong session, which is why this one
  is `async` and answers.
- `stopSession(sessionId:)` ends a session on the serving instance and keeps its row, where
  `close(sessionId:)` removes the row as well. It is not `stop()`, which ends this store's own
  connection. The route (`POST /api/sessions/{sid}/stop`) exists since 1.2.0 of this package and
  the Wietty that serves it. An older serving instance answers 404, which shows up in
  `lastActionError` as "Action failed (404).", the same as a session no row carries any more.
- Handle every `TerminalEndReason`. `serverTooOld` means the Mac speaks an older protocol than
  this client and needs updating; `refused` carries the server's own code and message, worth
  showing as is. Reconnecting can help only after `connectionLost`; after `sessionEnded`,
  `serverTooOld` or `refused` it cannot.
- `onEnded` fires at most once per `start()`, and never because you called `stop()`. Calling
  `start()` again before a queued `onEnded` was delivered drops that `onEnded`, so reconnect from
  `onEnded`, not blindly.
- After `stop()` returns, nothing is delivered if `stop()` was called on the callback queue (from
  a callback, or on the main actor for `RemoteTerminalConnection`). Called from any other thread,
  at most one callback that was already about to run may still run.
- A snapshot arrives as one message, and with real history it is larger than URLSession's
  default limit of 1 MiB (about 11 MB at 100,000 lines). `TerminalStreamConnection` raises its
  socket's limit to `StreamProtocol.maxMessageSize`, 64 MiB, the same limit `StreamFrameReader`
  applies on the Unix socket. Anything else that opens an `/attach` socket must do the same.
- `StreamFrameReader.failure` (1.1.0) is set as soon as the append that met a bad frame has
  returned its earlier messages, so a server need not wait for the next read to learn the stream
  is broken. It is nil on a sound stream and after a skipped frame of an unknown type.
  `StreamCodec.checkedSocketFrame(for:maxPayload:)` is `socketFrame(for:)` plus a size check that
  throws `.frameTooLarge` for a payload the reader would refuse; `socketFrame(for:)` is unchanged.
- Set the callbacks before `start()`: `TerminalStreamConnection` reads them on its callback queue
  without a lock. Any callback queue works, a concurrent one included, because the connection
  wraps it in a serial queue of its own. Messages always arrive in order and one at a time, and the
  next one is read from the socket only after the callback for the current one has returned. A slow
  callback therefore holds back the socket, which is what lets the server's bound and resync work.
  A callback that hands its work to a task and returns at once gives that up.
- Input typed after `start()` and before the server's hello has been accepted is held, not lost:
  up to 64 KiB in order (the oldest bytes go first beyond that). Every claim is held too, in
  order and never merged, because the server answers each claim once and `GridOwnership` counts
  each claim made; at most 64 are kept, the oldest dropped first, so a caller making more than 64
  claims before a hello would over count its unanswered claims. When the hello is accepted the
  held claims and then the held input are written, before anything sent later. If the stream
  ends instead, they are discarded. Before `start()` and after an end, `send` and `claim` write
  and hold nothing.
- Nested `ObservableObject` changes do not propagate. A view that only observes
  `RemoteWorkspacesController` will not redraw when one of its stores changes. Render each
  connection's UI from a subview that observes its own `RemoteWorkspaceStore` as an
  `@ObservedObject`, or snapshots arriving on a socket will never redraw anything.
