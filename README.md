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
| `TerminalStreamConnection` | One session's `/attach` stream, in both directions, bound to no actor |
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
- Set the callbacks before `start()`: `TerminalStreamConnection` reads them on its callback queue
  without a lock. Any callback queue works, a concurrent one included, because the connection
  wraps it in a serial queue of its own. Messages always arrive in order and one at a time.
- `send` and `claim` are dropped until the server's hello has been accepted, and after an end.
- Nested `ObservableObject` changes do not propagate. A view that only observes
  `RemoteWorkspacesController` will not redraw when one of its stores changes. Render each
  connection's UI from a subview that observes its own `RemoteWorkspaceStore` as an
  `@ObservedObject`, or snapshots arriving on a socket will never redraw anything.
