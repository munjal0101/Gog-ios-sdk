import Foundation
#if canImport(os)
import os
#endif

/// Minimal logging shim. Deliberately tiny — the SDK's contract is that failures are
/// *returned*, not logged. Logging is for the handful of conditions a caller cannot see:
/// bounded-cap evictions, and reconciliation outcomes.
enum GogLog {
    static func warn(_ message: String) {
        #if canImport(os)
        os_log("%{public}@", log: .default, type: .default, "[GOG] \(message)")
        #else
        FileHandle.standardError.write(Data("[GOG] \(message)\n".utf8))
        #endif
    }

    /// For a condition that is a BUG in the integration, not a fact about the world. Kept
    /// distinct from `warn` so it survives the log-level filter a shipping game will apply —
    /// mirrors Android's `Debug.LogError` on the overlay failsafe.
    static func error(_ message: String) {
        #if canImport(os)
        os_log("%{public}@", log: .default, type: .error, "[GOG] \(message)")
        #else
        FileHandle.standardError.write(Data("[GOG] \(message)\n".utf8))
        #endif
    }
}
