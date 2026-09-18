import Foundation
#if canImport(Security)
import Security
#endif

/// Somewhere small, durable, and not readable by other apps.
///
/// Behind a protocol so the session model, the refresh loop, and the PKCE flow store are all
/// testable without a Keychain — which does not exist on Linux and needs an entitlement-bearing
/// host app on Apple platforms.
protocol SecureStore: Sendable {
    func get(_ key: String) throws -> Data?
    func set(_ data: Data, for key: String) throws
    func remove(_ key: String) throws
}

/// Test double. Never used in a shipping build.
final class InMemorySecureStore: SecureStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    /// Set to make writes fail, so the "persist failed" branches can be exercised.
    var failWrites = false

    init(_ seed: [String: Data] = [:]) { storage = seed }

    func get(_ key: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }
    func set(_ data: Data, for key: String) throws {
        if failWrites { throw GogError.notConfigured("secure store unavailable") }
        lock.lock(); defer { lock.unlock() }
        storage[key] = data
    }
    func remove(_ key: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: key)
    }
    var keys: [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(storage.keys)
    }
}

#if canImport(Security)
/// The shipping store.
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — both halves deliberate:
///
/// **ThisDeviceOnly** blocks Keychain sync and backup restoration onto another device. A
/// session restored under a different owner is the identity-layer form of the mis-crediting
/// bug fixed in Phase 2, with higher stakes, and the answer is the same idea: state does not
/// cross an identity boundary.
///
/// **AfterFirstUnlock, not WhenUnlocked**, because invariant I6 requires launch sign-in to
/// survive process death, and background relaunches happen while the device is locked.
/// `WhenUnlocked` would make the session unreadable on exactly those relaunches and present
/// as a spurious sign-out — which testers would report as a bug, and which would be one.
struct KeychainSecureStore: SecureStore {
    let service: String

    init(service: String) { self.service = service }

    private func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    func get(_ key: String) throws -> Data? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw GogError.notConfigured("Keychain read failed (OSStatus \(status))")
        }
        return item as? Data
    }

    func set(_ data: Data, for key: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query(key) as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus == errSecItemNotFound {
            var addQuery = query(key)
            addQuery.merge(attributes) { current, _ in current }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw GogError.notConfigured("Keychain write failed (OSStatus \(addStatus))")
            }
            return
        }
        throw GogError.notConfigured("Keychain update failed (OSStatus \(updateStatus))")
    }

    func remove(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GogError.notConfigured("Keychain delete failed (OSStatus \(status))")
        }
    }
}
#endif
