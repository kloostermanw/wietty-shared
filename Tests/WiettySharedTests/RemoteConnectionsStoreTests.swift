import Testing
import Foundation
@testable import WiettyShared

@MainActor
@Suite struct RemoteConnectionsStoreTests {
    @Test func addUpdateRemoveRoundTrips() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let secretStore = InMemorySecretStore()
        let store = RemoteConnectionsStore(defaults: defaults, secretStore: secretStore)
        var connection = RemoteConnection(id: UUID(), name: "B", host: "1.2.3.4", port: 7434, token: "tok")

        store.add(connection)
        #expect(store.connections.count == 1)

        connection.name = "B2"
        store.update(connection)
        #expect(store.connections.first?.name == "B2")

        // A fresh store over the same defaults and secret store sees the change,
        // including the token round-tripping through the secret store.
        let reloaded = RemoteConnectionsStore(defaults: defaults, secretStore: secretStore)
        #expect(reloaded.connections.first?.name == "B2")
        #expect(reloaded.connections.first?.token == "tok")

        store.remove(id: connection.id)
        #expect(store.connections.isEmpty)
        #expect(secretStore.secret(for: connection.id.uuidString) == nil)
    }

    @Test func tokensAreNotWrittenToUserDefaults() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = RemoteConnectionsStore(defaults: defaults, secretStore: InMemorySecretStore())
        store.add(RemoteConnection(id: UUID(), name: "B", host: "1.2.3.4", port: 7434, token: "s3cret"))

        let raw = defaults.data(forKey: "wietty.remote.connections")!
        let text = String(data: raw, encoding: .utf8)!
        #expect(!text.contains("s3cret"))
    }

    @Test func aConnectionWithNoStoredTokenLoadsWithAnEmptyToken() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let secretStore = InMemorySecretStore()
        let store = RemoteConnectionsStore(defaults: defaults, secretStore: secretStore)
        let connection = RemoteConnection(id: UUID(), name: "B", host: "1.2.3.4", port: 7434, token: "tok")
        store.add(connection)
        secretStore.removeSecret(for: connection.id.uuidString)

        let reloaded = RemoteConnectionsStore(defaults: defaults, secretStore: secretStore)
        #expect(reloaded.connections.first?.token == "")
    }

    @Test func updatingAnUnknownConnectionDoesNothing() {
        let store = RemoteConnectionsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                          secretStore: InMemorySecretStore())
        store.update(RemoteConnection(id: UUID(), name: "ghost", host: "h", port: 1, token: "t"))
        #expect(store.connections.isEmpty)
    }
}
