# itermplex-shared

The platform neutral client for [iTermPlex](https://github.com/kloostermanw/itermplex)'s LAN
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
| `RemoteTerminalConnection`, `AttachMessage` | One session's `/attach` stream, in both directions |
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
