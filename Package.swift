// swift-tools-version: 6.0
import PackageDescription

// GOG iOS SDK.
//
// DEVELOPMENT layout (this file): one source target, buildable and testable on any
// platform with a Swift toolchain, so the transport/coins core can be exercised in CI
// without a Mac.
//
// RELEASE layout (Phase 1 memo §2): the same sources are compiled into ONE XCFramework
// shipped through two front doors —
//   1. dropped into the Unity UPM package at Runtime/Plugins/iOS/, the exact structural
//      mirror of Runtime/Plugins/Android/gog-sdk-android-core.aar; and
//   2. published from here as a binaryTarget for native SPM consumers:
//
//        .binaryTarget(name: "GOG",
//                      url: "https://…/GOG-<version>.xcframework.zip",
//                      checksum: "<sha256>")
//
// Both doors serve the SAME artifact, so the version square has exactly one binary to
// verify per platform. Do not add a second build path. CocoaPods is deliberately
// deferred — a podspec over this XCFramework is ~a day's work if a partner ever asks.
let package = Package(
    name: "GOG",
    platforms: [
        // 17.4, not 15. This is a SECURITY floor, not a compatibility one.
        //
        // ASWebAuthenticationSession's `.https(host:path:)` callback was introduced in
        // iOS 17.4 (confirmed by Apple Systems Engineering on the developer forums). Below
        // it, the only callback mechanism is a custom URL scheme. The hub-not-installed
        // path cannot avoid ASWebAuthenticationSession — see the Phase 3 plan §7 and the
        // TN3155 same-domain finding — so the callback mechanism is unavoidable too.
        //
        // GOG has no iOS installed base to protect and the test device is on 18.7, so the
        // cost today is zero. Still <= 18.7.
        .iOS("17.4"),
        .macOS(.v12),
    ],
    products: [
        .library(name: "GOG", targets: ["GOG"]),
    ],
    targets: [
        .target(name: "GOG", path: "Sources/GOG"),
        .testTarget(name: "GOGTests", dependencies: ["GOG"], path: "Tests/GOGTests"),
    ]
)
