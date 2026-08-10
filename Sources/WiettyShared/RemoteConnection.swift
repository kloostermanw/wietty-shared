import Foundation
import Combine

public struct RemoteConnection: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var token: String

    public init(id: UUID, name: String, host: String, port: Int, token: String) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.token = token
    }
}

@MainActor
public final class RemoteConnectionsStore: ObservableObject {
    /// Metadata persisted to UserDefaults. Deliberately excludes `token`, which is
    /// kept out of plaintext storage and lives in the `SecretStore` instead.
    private struct ConnectionMetadata: Codable {
        let id: UUID
        var name: String
        var host: String
        var port: Int
    }

    @Published public private(set) var connections: [RemoteConnection]
    private let defaults: UserDefaults
    private let secretStore: SecretStore
    private let key = "wietty.remote.connections"

    public init(defaults: UserDefaults = .standard, secretStore: SecretStore = KeychainSecretStore()) {
        self.defaults = defaults
        self.secretStore = secretStore
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([ConnectionMetadata].self, from: data) {
            connections = decoded.map { metadata in
                RemoteConnection(
                    id: metadata.id,
                    name: metadata.name,
                    host: metadata.host,
                    port: metadata.port,
                    token: secretStore.secret(for: metadata.id.uuidString) ?? ""
                )
            }
        } else {
            connections = []
        }
    }

    public func add(_ connection: RemoteConnection) {
        connections.append(connection)
        persist()
        secretStore.setSecret(connection.token, for: connection.id.uuidString)
    }

    public func update(_ connection: RemoteConnection) {
        guard let i = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        connections[i] = connection
        persist()
        secretStore.setSecret(connection.token, for: connection.id.uuidString)
    }

    public func remove(id: UUID) {
        connections.removeAll { $0.id == id }
        persist()
        secretStore.removeSecret(for: id.uuidString)
    }

    private func persist() {
        let metadata = connections.map { ConnectionMetadata(id: $0.id, name: $0.name, host: $0.host, port: $0.port) }
        if let data = try? JSONEncoder().encode(metadata) { defaults.set(data, forKey: key) }
    }
}
