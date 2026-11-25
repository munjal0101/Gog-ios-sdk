import Foundation
#if canImport(Security)
import Security
#endif

// ─────────────────────────────────────────────────────────────────────────────
// Install handoff: sign-in that survives an App Store install.
//
// A launch link (`trySignInFromLaunch(url:)`) only works when the game is already installed.
// When it is not, the link goes to the App Store, iOS drops the code on the way, and the
// freshly installed game would open signed out. So when the player taps a game, the hub ALSO
// writes the same single-use code into a Keychain access group that every app on the team
// shares. On its first launch the game reads it, deletes it, and exchanges it — the player
// is signed in with the hub's account without seeing a screen.
//
// CONTRACT with the hub (apps/hub/src/lib/install-handoff.ts). It is exactly what
// expo-secure-store 15 writes for `setItemAsync(key, value, { keychainService, accessGroup })`,
// so the two sides must change together:
//
//   kSecAttrAccessGroup  "<TeamID>.online.godofgaming.shared"
//   kSecAttrService      "online.godofgaming.install-handoff:no-auth"
//                        (expo appends ":no-auth" to the keychainService it is given)
//   kSecAttrAccount      UTF-8 BYTES (Data, not String) of the lower-case game id
//   kSecValueData        UTF-8 JSON {"code": "<wrapper code>", "expires_at": "<ISO 8601>"}
//
// ENTITLEMENT ORDER MATTERS. Both the hub and every game list, in `keychain-access-groups`:
//   1. $(AppIdentifierPrefix)<own bundle id>          ← FIRST: the default group for writes
//   2. $(AppIdentifierPrefix)online.godofgaming.shared
// The first entry is where every Keychain write WITHOUT an explicit group lands. If the shared
// group came first, each app's own session would be written where the whole team can read it.
//
// The Team ID is read at runtime from this app's own default group, never hard-coded, so the
// feature keeps working if the apps move to another developer account together.
// ─────────────────────────────────────────────────────────────────────────────

/// One code left by the hub for this game.
struct InstallHandoff: Equatable, Sendable {
    let code: String
    /// Nil when the hub wrote no parseable expiry; the server still enforces it.
    let expiresAt: Date?
}

enum InstallHandoffContract {
    static let accessGroupSuffix = "online.godofgaming.shared"
    static let service = "online.godofgaming.install-handoff:no-auth"

    static func account(for gameId: UUID) -> Data {
        Data(gameId.uuidString.lowercased().utf8)
    }

    /// The shared group for a given default group: "<TeamID>.<anything>" → "<TeamID>.online.godofgaming.shared".
    static func sharedGroup(fromDefaultGroup group: String) -> String? {
        guard let dot = group.firstIndex(of: "."), dot != group.startIndex else { return nil }
        return String(group[..<dot]) + "." + accessGroupSuffix
    }

    static func decode(_ data: Data) -> InstallHandoff? {
        struct Wire: Decodable {
            let code: String
            let expiresAt: String?
            enum CodingKeys: String, CodingKey { case code; case expiresAt = "expires_at" }
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data),
              !wire.code.isEmpty else { return nil }
        return InstallHandoff(code: wire.code, expiresAt: wire.expiresAt.flatMap(parseDate))
    }

    /// The hub writes `Date.prototype.toISOString()` (milliseconds, `Z`); accept plain seconds too.
    static func parseDate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }
}

/// Where the hub's code is read from. A protocol so the flow is testable without a Keychain.
protocol InstallHandoffStore: Sendable {
    /// Read AND delete this game's code. Single use: whatever happens next, it is gone.
    func take(gameId: UUID) -> InstallHandoff?
    /// Delete this game's code without using it (the launch link already carried it).
    func discard(gameId: UUID)
}

/// Linux, tests, and any platform without a Keychain: there is never a handoff.
struct NoInstallHandoffStore: InstallHandoffStore {
    func take(gameId: UUID) -> InstallHandoff? { nil }
    func discard(gameId: UUID) {}
}

/// Test double.
final class InMemoryInstallHandoffStore: InstallHandoffStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [UUID: InstallHandoff] = [:]

    init(_ seed: [UUID: InstallHandoff] = [:]) { items = seed }

    func take(gameId: UUID) -> InstallHandoff? {
        lock.lock(); defer { lock.unlock() }
        return items.removeValue(forKey: gameId)
    }
    func discard(gameId: UUID) {
        lock.lock(); defer { lock.unlock() }
        items.removeValue(forKey: gameId)
    }
    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return items.isEmpty
    }
}

#if canImport(Security) && os(iOS)
/// The shipping store: the team-shared Keychain group the hub writes to.
struct KeychainInstallHandoffStore: InstallHandoffStore {

    func take(gameId: UUID) -> InstallHandoff? {
        guard let base = baseQuery(gameId: gameId) else { return nil }
        var read = base
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status == errSecMissingEntitlement {
                GogLog.warn("install handoff: the app lacks the keychain-access-groups entitlement "
                            + "for \(InstallHandoffContract.accessGroupSuffix); hub sign-in after an "
                            + "App Store install is off")
            } else if status != errSecItemNotFound {
                GogLog.warn("install handoff: Keychain read failed (OSStatus \(status))")
            }
            return nil
        }
        SecItemDelete(base as CFDictionary)
        return InstallHandoffContract.decode(data)
    }

    func discard(gameId: UUID) {
        guard let base = baseQuery(gameId: gameId) else { return }
        SecItemDelete(base as CFDictionary)
    }

    private func baseQuery(gameId: UUID) -> [String: Any]? {
        guard let group = Self.sharedAccessGroup else { return nil }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccessGroup as String: group,
            kSecAttrService as String: InstallHandoffContract.service,
            kSecAttrAccount as String: InstallHandoffContract.account(for: gameId),
        ]
    }

    /// "<TeamID>.online.godofgaming.shared", the Team ID taken from this app's default group.
    /// Computed once; nil when the Keychain cannot tell us (no entitlements, simulator quirks).
    static let sharedAccessGroup: String? = {
        guard let group = defaultAccessGroup() else { return nil }
        return InstallHandoffContract.sharedGroup(fromDefaultGroup: group)
    }()

    /// The group a write without `kSecAttrAccessGroup` lands in: "<TeamID>.<first entitlement>".
    /// Read back from a tiny probe item in this app's own space.
    private static func defaultAccessGroup() -> String? {
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "online.godofgaming.team-probe",
            kSecAttrAccount as String: "probe",
        ]
        var lookup = probe
        lookup[kSecReturnAttributes as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        var status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound {
            var add = probe
            add[kSecValueData as String] = Data()
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecReturnAttributes as String] = true
            status = SecItemAdd(add as CFDictionary, &result)
        }
        guard status == errSecSuccess, let attributes = result as? [String: Any] else { return nil }
        return attributes[kSecAttrAccessGroup as String] as? String
    }
}
#endif
