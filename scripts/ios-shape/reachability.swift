// Compiles ONLY if every Apple-only branch in the package was actually compiled.
//
// Each symbol below exists solely inside a `#if canImport(...)` block. If a branch were being
// skipped — which is exactly the failure that let three real bugs sit in this package
// undetected — the corresponding line here stops resolving and this file fails to build.
import Foundation

@MainActor func __gog_reachability_probe() {
    _ = KeychainSecureStore(service: "probe")   // #if canImport(Security)
    _ = UIKitAdPresenter()                      // #if canImport(UIKit)
    _ = ASWebAuthPresenterImpl()                // #if canImport(AuthenticationServices) && UIKit
}
