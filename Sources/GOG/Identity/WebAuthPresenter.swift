import Foundation

/// Presents the hub's web sign-in and returns the URL it calls back with.
///
/// Behind a protocol for the usual reason: everything around it — building the hub URL,
/// persisting the PKCE verifier, validating the return, extracting the code, exchanging it —
/// is then testable with no browser, no entitlement and no Apple account. Only the
/// presentation needs a device.
protocol WebAuthPresenter: Sendable {
    /// Open `url` in a contained browser and resolve with the callback URL.
    ///
    /// Throws `GogError.signInCancelled` when the player dismisses it.
    ///
    /// - Parameter switchAccount: discard shared browser cookies for this attempt.
    func authenticate(url: URL, callbackHost: String, callbackPath: String,
                      switchAccount: Bool) async throws -> URL
}

/// One-shot latch. Main-actor confined by use — `ASWebAuthenticationSession` calls its
/// completion handler on the main queue, and the only other claimant runs there too.
final class OneShot {
    private var taken = false
    /// True for exactly one caller, ever.
    func claim() -> Bool {
        if taken { return false }
        taken = true
        return true
    }
}

/// Used on platforms with no `AuthenticationServices`, and in tests.
struct UnavailableWebAuthPresenter: WebAuthPresenter {
    func authenticate(url: URL, callbackHost: String, callbackPath: String,
                      switchAccount: Bool) async throws -> URL {
        throw GogError.notConfigured(
            "Web sign-in is not available on this platform. On iOS this is "
            + "ASWebAuthenticationSession; it requires the Associated Domains entitlement for "
            + "\(callbackHost).")
    }
}

#if canImport(AuthenticationServices) && canImport(UIKit)
import AuthenticationServices
import UIKit

/// `ASWebAuthenticationSession`.
///
/// ⚠️ **Never compiled here.** `AuthenticationServices` + `UIKit` only exist on an Apple
/// target, so this file is first compiled by `xcodebuild -destination 'generic/platform=iOS'`.
/// Deliberately plain for that reason.
///
/// **Why this API rather than opening Safari.** Apple's TN3155 documents that a Universal
/// Link whose domain matches the previous navigation does NOT open the app — the browser
/// assumes the user means to keep browsing. A plain-Safari fallback therefore strands a live
/// 120-second credential in the browser with nothing to receive it. Inside
/// `ASWebAuthenticationSession` the session intercepts its own callback rather than relying
/// on Universal-Link routing, so that rule does not apply.
///
/// **Why the deployment floor is 17.4.** `Callback.https(host:path:)` arrived in iOS 17.4.
/// Below it the only mechanism is a custom URL scheme, which design doc L1 rules out.
///
/// **`prefersEphemeralWebBrowserSession` is false**, so an existing hub session in Safari
/// makes sign-in seamless. That sharing has a cost the hub must cover: it must never
/// auto-submit on a live cookie session, or player B picking up the device is signed in as
/// player A. See the hub brief. `switchAccount` forces an ephemeral session for the
/// "not you?" path.
@MainActor
final class ASWebAuthPresenterImpl: NSObject, WebAuthPresenter,
                                    ASWebAuthenticationPresentationContextProviding {

    /// 🔴 `nonisolated`, and it has to be.
    ///
    /// `GogIdentity` is an actor, and its initialiser is synchronous and nonisolated — so the
    /// default presenter is constructed from a nonisolated context. A `@MainActor` class gets a
    /// `@MainActor` initialiser by default, and calling that from there is a hard Swift 6 error:
    /// *"call to main actor-isolated initializer 'init()' in a synchronous nonisolated context"*.
    ///
    /// Safe because this type has **no stored properties** — `super.init()` is the whole body,
    /// so there is no isolated state to race on. Everything that genuinely needs the main actor
    /// (`start`, and the anchor lookup) is isolated at the member level instead.
    ///
    /// This was the one real defect the shim type-check caught: on Linux the whole file is
    /// `#if canImport`-ed away, so nothing had ever checked it.
    nonisolated override init() { super.init() }

    nonisolated func authenticate(url: URL, callbackHost: String, callbackPath: String,
                                  switchAccount: Bool) async throws -> URL {
        try await MainActor.run {
            self.start(url, callbackHost, callbackPath, switchAccount)
        }.value
    }

    /// ⚠️ `session` is deliberately a LOCAL, not a stored property.
    ///
    /// The famous `ASWebAuthenticationSession` bug is failing to retain it, and the reflex on
    /// reading this is to "fix" that. Apple is explicit that it does not apply here: *"if you
    /// have a deployment target of iOS 13 or later, the session keeps a strong reference to
    /// itself until the authentication process completes to prevent the system from
    /// deallocating the closure."* Our floor is 17.4. Storing it would add a reference to
    /// manage and a stale-session hazard, and buy nothing.
    private func start(_ url: URL, _ callbackHost: String, _ callbackPath: String,
                       _ ephemeral: Bool) -> Task<URL, Error> {
        Task { @MainActor in
            // 🔴 Exactly-once on the continuation. Resuming a CheckedContinuation twice is a
            // hard crash, not an error, and there are two resume sites that could in principle
            // both run: the completion handler, and the `start()` failure below. Apple does not
            // document whether a refused `start()` also invokes the handler, and "probably not"
            // is not a basis for a fatalError in the sign-in path.
            let resumed = OneShot()
            return try await withCheckedThrowingContinuation { continuation in
                let session = ASWebAuthenticationSession(
                    url: url,
                    callback: .https(host: callbackHost, path: callbackPath)
                ) { callbackURL, error in
                    guard resumed.claim() else { return }
                    if let callbackURL {
                        continuation.resume(returning: callbackURL)
                        return
                    }
                    if let error = error as? ASWebAuthenticationSessionError,
                       error.code == .canceledLogin {
                        continuation.resume(throwing: GogError.signInCancelled)
                        return
                    }
                    continuation.resume(throwing: GogError.network(
                        .transport(error.map { String(describing: type(of: $0)) } ?? "unknown"),
                        retryable: true))
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = ephemeral
                if !session.start(), resumed.claim() {
                    continuation.resume(throwing: GogError.notConfigured(
                        "ASWebAuthenticationSession could not start. The Associated Domains "
                        + "entitlement for \(callbackHost) is required for an https callback."))
                }
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }
}
#endif
