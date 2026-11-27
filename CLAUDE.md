# wietty-shared

A Swift package, not an app: the platform neutral **client** of Wietty's LAN remote protocol,
consumed by both the macOS app and the iPadOS app. It also holds the terminal stream's messages and
their framings, which the serving side of the macOS app uses too. This is where the wire format is
defined, so a change here reaches each app when it moves its pin.

## Project
This package is one of three repositories. It exists so the protocol is defined once instead of
copied into two clients.

|name          | target  | github                                         | path                   |
|--------------|---------|------------------------------------------------|------------------------|
|wietty        | mac os  | https://github.com/kloostermanw/wietty         | ~/repos/wietty         |
|wietty-ios    | ipad os | https://github.com/kloostermanw/wietty-ios     | ~/repos/wietty-ios     |
|wietty-shared | library | https://github.com/kloostermanw/wietty-shared  | ~/repos/wietty-shared  |

What belongs here and what does not:

- **Here: the controlling side.** `RemoteWorkspaceStore`, `RemoteWorkspacesController`,
  `TerminalStreamConnection`, `RemoteTerminalConnection`, `GridOwnership`,
  `RemoteSnapshotDecoder`, `RemoteEndpoints`, `RemoteConnection`, `RemoteConnectionsStore`,
  `SecretStore`, and the remote models. `RemoteTerminalConnection` is used by the iPadOS app
  only: the macOS app shows a terminal of another Mac through `TerminalStreamConnection` (its
  `RemoteSocketLink`).
- **Here, for both sides: the stream's messages.** `StreamMessage`, `StreamProtocol`,
  `StreamCodec` and `StreamFrameReader`. The serving side of the macOS app (`WiettyCore`) links
  this package for them: `RemoteServer` speaks the WebSocket framing on `WS /attach`, and
  `LocalStreamServer` speaks the Unix socket framing to the app's own pane (`LocalSocketLink`),
  which is that framing's only use. So a change to these types changes the server as well as
  the clients.
- **Not here: the rest of the served side.** `RemoteServer`, `LocalStreamServer`,
  `WorkspaceSerializer`, `GhosttyService`, `TerminalRelay`, `RawPTY`, `PaneStreamHub` stay in
  the macOS repo, which is the only instance that serves.
- **Not here: either app's local types.** No `Project`, no `GitInfo`, no placeholder for a remote
  workspace's non existent local folder. The macOS app keeps a `RemoteProjectAdapter` for that
  precisely so it does not leak in here. A remote workspace has no filesystem, by design.

The protocol reference lives in the macOS repo at `docs/remote-access.md`.

## Setup
Plain Swift Package Manager. There is no XcodeGen, no `project.yml`, and no `.xcodeproj` to
generate; `Package.swift` is the whole build definition.

```sh
swift build
swift test
```

Because both apps depend on this, verify it still builds for **both** platforms before publishing:

```sh
xcodebuild -scheme wietty-shared -destination 'platform=macOS' build
xcodebuild -scheme wietty-shared -destination 'generic/platform=iOS' build
```

The scheme is `wietty-shared` (the package name), not `WiettyShared` (the library product
name). Using the product name fails to resolve a scheme.

## Constraints that make this package shareable
Breaking any of these turns a shared package back into two copies, so they are not preferences:

- **Foundation, Combine, and Security only.** No AppKit, no UIKit, no SwiftUI. The package builds
  for either platform without conditionals, and importing a UI framework would end that.
- **iOS 16 and macOS 14 minimums.** The iPadOS client supports iOS 16, so the `@Observable` macro
  (iOS 17) is unavailable: observable types are `ObservableObject` with `@Published private(set)`.
  Do not migrate to `@Observable` while iOS 16 is supported.
- **Nested `ObservableObject` changes do not propagate.** `RemoteWorkspacesController.stores` holds
  stores, so a consumer observing only the controller never redraws on a snapshot. This is a
  documented consumer obligation, not something the package can fix; see the README.
- **Version honestly.** Both apps pin a released tag. A breaking signature change needs a new minor
  (as `onEnded` carrying a `TerminalEndReason` did in 0.2.0), not a patch.

## Documentation
There is no `documentation/` folder here. `README.md` is the reference, and its "Consuming this
package" section carries the rules a consumer cannot discover from the type system (gating
`workspaces` on `state`, calling `sync()`, the nested observation trap). Keep that section in sync
in the same change whenever behavior a consumer depends on changes.

The two sockets differ in what the tests cover:

- **`TerminalStreamConnection` has an injection seam.** Its socket sits behind
  `WebSocketTransport`, and `TerminalStreamSocketLoopTests` drives the receive loop and the
  writes through a `FakeTransport`: the `task === socket` guard against a stale frame, hello,
  receive failure or send failure, one receive at a time, the ends, the message size limit, the
  splitting of large input, and what is held before the hello. Not covered is
  `URLSessionWebSocketTask` itself over a live connection (one test only checks that the limit
  reaches a real, never resumed task). The macOS repo's `scripts/remote-surface-check.sh` runs
  this client against a real `RemoteServer` on 127.0.0.1.
- **`RemoteWorkspaceStore` has none.** It opens its `/control` socket and its REST requests on
  `URLSession.shared` directly. The tests cover the pure parts (applying a snapshot, the state
  for a probe status, the action error for a result, the activation reply) and a URL that
  cannot be built. The receive loop, its `task === self.socket` guard, the drop, the probe and
  the reconnect after two seconds are verified by inspection, so a change to them needs manual
  verification against a live server, in the macOS app, before publishing.

Never use dashes (— or -) as punctuation in documentation or README files. Rephrase using periods,
commas, or parentheses instead.

## General
Do not tell me I am right all the time. Be critical. We're equals. Try to be neutral and objective.
Do not excessively use emojis.

## Using GitHub
For questions about GitHub, use the gh tool.
Never mention Claude Code in PR descriptions, PR comments, or issue comments.
Do not include a "Test plan" section in PR descriptions.

## Git
Git flow: work off `develop` on a `feature/...` branch, and open PRs against `develop` (it is the
default branch). Name the branch `feature/issue-<number>` when an issue exists. A release is a tag
both apps pin, so publishing is deliberate: merge `develop` into `main` and tag `X.Y.Z` there.

use /create-commit to create a commit message
use /create-pr to create a pr message

A global `commit-msg` hook rejects any commit message containing a word from
`~/.config/git/disallowed-words.txt`, matched whole-word and case-insensitively. That list currently
includes `claude`, `Co-Authored-By`, `wip`, `temp`, `fixme`, and `foobar`, so a "wip:" subject or a
co-author trailer is refused. Reword the message; do not work around it with `--no-verify`.
