import Foundation
import Security

/// Abstraction over a place to stash small secrets (remote connection tokens), so
/// production code can use the Keychain while tests use an in-memory stand-in.
public protocol SecretStore {
    func secret(for key: String) -> String?
    func setSecret(_ value: String, for key: String)
    func removeSecret(for key: String)
}

/// Keychain-backed `SecretStore`. Stores each secret as a generic password item under a
/// fixed service, keyed by `account`. Best effort: any Keychain failure is swallowed
/// (returns nil, or no-ops) rather than crashing the app.
///
/// On iOS this needs a signed build. An unsigned binary has no `application-identifier`,
/// so `SecItemAdd` fails with `errSecMissingEntitlement` and every write silently does
/// nothing.
public struct KeychainSecretStore: SecretStore {
    private let service = "eu.kloosterman.itermplex.remote"

    public init() {}

    private func query(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    public func secret(for key: String) -> String? {
        var attributes = query(for: key)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Tries the update first and only falls back to add when the Keychain reports the
    /// item genuinely missing (`errSecItemNotFound`), rather than deciding between the
    /// two by reading first with `secret(for:)`. That read cannot tell "no such item"
    /// apart from "the read failed", and on iOS it fails routinely: a generic password
    /// item defaults to `kSecAttrAccessibleWhenUnlocked`, so `SecItemCopyMatching`
    /// returns `errSecInteractionNotAllowed` while the device is locked. Read-then-branch
    /// would treat that as "missing", take the add path, get `errSecDuplicateItem` back,
    /// swallow it, and leave the old token in place, silently, on a device that most
    /// users keep locked most of the time.
    public func setSecret(_ value: String, for key: String) {
        guard let data = value.data(using: .utf8) else { return }
        let base = query(for: key)

        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return }
        var addQuery = base
        addQuery[kSecValueData as String] = data
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    public func removeSecret(for key: String) {
        SecItemDelete(query(for: key) as CFDictionary)
    }
}
