import Foundation
import Combine

/// Maps persisted `RemoteConnection`s to live `RemoteWorkspaceStore`s: starts a store
/// for each new connection, replaces the store for any connection whose id was kept but
/// whose details changed, and stops and drops the store for any connection that has been
/// removed. Callers render one section per entry in `stores`, and call `sync()` after any
/// add, edit, or remove.
///
/// Note for SwiftUI callers: `stores` holds `ObservableObject`s, and nested observable
/// changes do not propagate to a view that only observes this controller. Render each
/// section from a subview that takes its store as its own `@ObservedObject`, or snapshots
/// arriving on a socket will never redraw anything.
@MainActor
public final class RemoteWorkspacesController: ObservableObject {
    private let connections: RemoteConnectionsStore
    @Published public private(set) var stores: [UUID: RemoteWorkspaceStore] = [:]

    public init(connections: RemoteConnectionsStore) {
        self.connections = connections
    }

    public func sync() {
        let ids = Set(connections.connections.map(\.id))
        for connection in connections.connections {
            if let existing = stores[connection.id], existing.connection == connection { continue }
            stores[connection.id]?.stop()
            let store = RemoteWorkspaceStore(connection: connection)
            stores[connection.id] = store
            store.start()
        }
        for (id, store) in stores where !ids.contains(id) {
            store.stop()
            stores[id] = nil
        }
    }
}
