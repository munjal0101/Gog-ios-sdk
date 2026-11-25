import Foundation

/// Runs the hub side of "Sign in with GOG" and returns the launch link it comes back with.
///
/// Behind a protocol for the usual reason: everything around it — building the hub URL,
/// persisting the PKCE verifier, validating the return, extracting the code, exchanging it —
/// is then testable with no hub, no entitlement and no Apple account. Only the app switch
/// needs a device.
///
/// (The name predates the hub app: sign-in used to run on a web page with an email one-time
/// password. That page is gone from games; sign-in now goes through the Gully Games app.)
protocol WebAuthPresenter: Sendable {
    /// Open the hub with `url` and resolve with the launch link the hub sends back.
    ///
    /// Throws `GogError.signInCancelled` when the player comes back without completing, and
    /// `GogError.hubNotInstalled` when there is no hub to open.
    ///
    /// - Parameter switchAccount: kept for API stability; the hub app decides the account.
    func authenticate(url: URL, callbackHost: String, callbackPath: String,
                      switchAccount: Bool) async throws -> URL
}

/// A presenter that is waiting for the hub to answer through this game's launch link.
///
/// The hub cannot hand a result back in-process the way Android's activity result does: it
/// opens `https://link.godofgaming.online/launch/<game>#code=…`, which iOS delivers to the
/// game like any other Universal Link. `GogIdentity.trySignInFromLaunch(url:)` offers every
/// launch link here first; a waiting sign-in takes it and finishes the exchange itself.
protocol LaunchCallbackReceiver: Sendable {
    /// True when a sign-in was waiting and has taken `url`.
    func deliver(_ url: URL) -> Bool
}

/// One-shot latch. True for exactly one caller, ever.
final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}

/// Used on platforms with no UIKit, and in tests.
struct UnavailableWebAuthPresenter: WebAuthPresenter {
    func authenticate(url: URL, callbackHost: String, callbackPath: String,
                      switchAccount: Bool) async throws -> URL {
        throw GogError.notConfigured(
            "Sign-in through the Gully Games app is only available on iOS.")
    }
}

#if canImport(UIKit)
import UIKit

/// Sign-in through the Gully Games hub APP: no web page, no email, no one-time password.
///
/// 1. Open `gullygames://game-auth?game_id=…&code_challenge=…`. The hub — where the player
///    is already signed in — shows "Signing you in to <game>…", mints a code bound to this
///    game and this PKCE challenge, and opens this game's launch link with it.
/// 2. The link arrives through the game's normal Universal Link path and is handed here by
///    `GogIdentity.trySignInFromLaunch(url:)`; `signInWithGog` then exchanges it WITH the
///    verifier only this process holds.
///
/// Why this is safe without a caller check like Android's: the code can only ever travel to
/// `link.godofgaming.online/launch/<game id>`, which Apple's association file routes to the
/// real game and nothing else — an app that opened the hub pretending to be this game would
/// never receive the code, and could not redeem it without the verifier anyway.
///
/// If the hub is not installed, its App Store page opens instead and this throws
/// `.hubNotInstalled`. If the player comes back without finishing, it throws
/// `.signInCancelled` shortly after the game is active again.
///
/// ⚠️ **Never compiled here** (UIKit exists only on an Apple target). Deliberately plain.
final class HubAppSignInPresenter: WebAuthPresenter, LaunchCallbackReceiver, @unchecked Sendable {

    /// How long to wait, once the game is active again, for the hub's link to land before
    /// calling it a cancel. The link and the activation arrive close together, in either order.
    static let returnGrace: TimeInterval = 2.5

    private let lock = NSLock()
    private var waiting: CheckedContinuation<URL, Error>?
    private var leftApp = false
    /// Which attempt a delayed cancel belongs to, so it can never cancel a LATER sign-in.
    private var attempt = 0
    private var observers: [NSObjectProtocol] = []

    func authenticate(url: URL, callbackHost: String, callbackPath: String,
                      switchAccount: Bool) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            // GogIdentity's in-progress guard makes this unreachable; never strand a caller.
            let stale = waiting
            waiting = continuation
            leftApp = false
            attempt += 1
            lock.unlock()
            stale?.resume(throwing: GogError.signInCancelled)

            Task { @MainActor in
                self.watchForReturn()
                // `opened` is false when no installed app handles the hub's scheme — no
                // LSApplicationQueriesSchemes entry needed, unlike canOpenURL.
                UIApplication.shared.open(url, options: [:]) { opened in
                    guard !opened else { return }
                    UIApplication.shared.open(GogHosts.hubAppStoreURL, options: [:],
                                              completionHandler: nil)
                    self.finish(.failure(GogError.hubNotInstalled))
                }
            }
        }
    }

    func deliver(_ url: URL) -> Bool {
        lock.lock()
        guard let continuation = waiting else { lock.unlock(); return false }
        waiting = nil
        lock.unlock()
        stopWatching()
        continuation.resume(returning: url)
        return true
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let continuation = waiting
        waiting = nil
        lock.unlock()
        stopWatching()
        continuation?.resume(with: result)
    }

    private func cancel(ifStill expected: Int) {
        lock.lock(); let same = attempt == expected; lock.unlock()
        if same { finish(.failure(GogError.signInCancelled)) }
    }

    /// Cancel only after the player has actually LEFT for the hub and come back without a link.
    @MainActor
    private func watchForReturn() {
        let center = NotificationCenter.default
        let resign = center.addObserver(forName: UIApplication.willResignActiveNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.leftApp = true; self.lock.unlock()
        }
        let active = center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            let back = self.leftApp && self.waiting != nil
            let current = self.attempt
            self.lock.unlock()
            guard back else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.returnGrace) { [weak self] in
                self?.cancel(ifStill: current)
            }
        }
        lock.lock(); observers = [resign, active]; lock.unlock()
    }

    private func stopWatching() {
        lock.lock(); let current = observers; observers = []; lock.unlock()
        current.forEach(NotificationCenter.default.removeObserver)
    }
}
#endif
