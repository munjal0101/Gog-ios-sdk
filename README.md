# GOG iOS SDK

Native iOS SDK for GOG — one identity and one GG Coins wallet across every integrated game.
The behavioural reference is the shipped Android SDK; this is not a port of its Kotlin/C#
specifics, only of its contracts.

**Status: Android behavioural parity, minus what needs an Apple Developer account.** Root
facade, auth, coins, ads, playtime and the identity layer. See "What is deliberately not
here", and `ios-sdk-android-parity.md` for the divergence-by-divergence account — including
the eighteen found by reading all 34 Android implementation files rather than the contract.

Parity target is `docs/sdk-api-contract.md` §2 — *"The frozen public surface"* — plus the
behaviours of the shipped v0.2.1 Unity SDK, read from source rather than recalled.

---

## Layout

```
Package.swift              development layout: one source target, testable anywhere
Sources/GOG/
  GogSDKVersion.swift      generated; the Swift corner of the version square
  GogError.swift           THE error taxonomy — one closed enum
  GogSessionProvider.swift the token + userScope seam (identity stays outside)
  GogConfiguration.swift   base URL (one source of truth), game id, §1.5 handshake
  Internal/
    GogTransport.swift     the network seam + the only file touching URLSession
    GogHTTP.swift          the one HTTP + parse pipeline
    GogErrorMapper.swift   the one place a non-2xx becomes a GogError
    GogLog.swift
  Coins/
    WalletModels.swift     DTOs — every property non-optional, on purpose
    IdempotencyLog.swift   versioned, durable write-ahead log
    GogCoins.swift         the public coins surface
  Ads/
    GogAds.swift           showInterstitial + the three silent-failure rules
    GogAdModels.swift      outcome types + two-stage directive decoding
    AdImpressionIndex.swift persisted, monotonic, game-invisible
    AdPresenter.swift      the render seam
    UIKitAdPresenter.swift the overlay — never compiled here
    GogAdmob.swift         AdMob interstitial pipeline — guards, load timeout, exactly-once
    GmaRuntimeBackend.swift the only file touching Google Mobile Ads, by name — never compiled here
  Playtime/
    PlaytimeMeter.swift    active/idle accrual — an exact port of Android's arithmetic
    PlaytimeEvents.swift   the engagement.playtime envelope + the /events uploader
    GogPlaytime.swift      coordinator + durable queue
    PlaytimeAutoHook.swift lifecycle + input hookup — never compiled here
  Identity/
    WebAuthPresenter.swift ASWebAuthenticationSession seam — never compiled here
    GogAuthEvents.swift    GogSession, sign-out reasons, the event hub
    GogHosts.swift         the TWO hosts, the hub URL builder, the delimiter policy
    GogIdentity.swift      session owner; exchange, single-flight refresh, userScope
    GogSession.swift       session model + the three response DTOs
    PKCE.swift             S256 pair + the PERSISTED in-flight flow
    SecureStore.swift      protocol + Keychain impl + in-memory fake
    LaunchLink.swift       host/path/segment validation (no code extraction)
  Internal/Crypto/
    SHA256.swift           CryptoKit on Apple; portable fallback for Linux CI
  Bridge/
    GogUnityBridge.swift   the C ABI the Unity binding calls on iOS — auth + playtime ONLY
Tests/GOGTests/            243 tests: Android regressions, account boundary, identity,
                           hosts, ads, AdMob, playtime, launch codes, facade, parity gaps,
                           the Unity bridge's wire format
scripts/
  lib/slice-assertions.sh  pure assertion functions — testable without macOS
  selftest.sh              31 assertion tests; runs anywhere
  stamp-version.sh         writes the version square's Swift corner
  build-xcframework.sh     archive -> create-xcframework -> VERIFY -> checksum
  verify-xcframework.sh    standalone re-verification of a built artifact
dist/                      XCFramework output — the artifact both doors ship
```

## Distribution (Phase 1 memo §2, ratified)

One XCFramework, two front doors, one artifact:

1. **Unity UPM** — dropped at `Runtime/Plugins/iOS/`, the exact structural mirror of
   `Runtime/Plugins/Android/gog-sdk-android-core.aar`. Unity does not participate in SPM or
   CocoaPods resolution, so this makes the Phase 4 integration a file drop.
2. **SPM** — `.binaryTarget(url:checksum:)` over the same zip, for native consumers.

CocoaPods is deferred, not rejected: a podspec over an existing XCFramework is roughly a
day's work if a partner asks for it.

### The Unity door, concretely

The product is declared `.dynamic`, so the archive is a real `GOG.framework` (the automatic
type yields a bare `GOG.o`). Unity 6 imports the `.xcframework` from `Plugins/iOS` natively,
and the package's `GogIosPostProcessor` embeds it, adds `applinks:link.godofgaming.online`,
and writes the iOS AdMob app id.

C# never sees Swift: `IosAuthBridge.cs` calls the `gog_bridge_*` C functions in
`Bridge/GogUnityBridge.swift` through `[DllImport("__Internal")]`. That bridge boots
`GogIdentity` and `GogPlaytime` and **nothing else** — coins and ads stay in C# on both
platforms, exactly as on Android, so the Swift wallet and ad pipeline are never started twice.
The version handshake reads `GogSDKVersion.compiled`, the same bytes the build's `strings`
check verifies.

## The seven things this code exists to get right

**1. It cannot hang, and it cannot wrong-succeed.** `GogHTTP.send` either returns a decoded
value or throws a `GogError` — exactly once, by language guarantee, because a function
returns or throws. On Android the equivalent guarantee had to be hand-built, and the one
path that missed it (an unguarded parse inside a `finally` with no `catch`) hung the game
forever on a malformed 200. Every DTO property here is non-optional, so a 200 missing a
field throws `.malformedResponse(missingField:)` instead of default-filling — which is how
the C# coins path could report `balance = 0` for a response that never contained a balance.

**2. `@MainActor` and `async throws` make two invariants compile-time.** I2 (delivered
exactly once) and I3 (delivered on the main thread) were runtime conventions on Android.
Here they are checked by the compiler. That is the whole argument for the idiom.

**3. The wallet path asymmetry is mirrored verbatim.** Balance reads `/me/wallet`; earn and
spend post to `/wallet/earn` and `/wallet/spend`. Different prefixes, same wallet. It looks
like an inconsistency and is not one — tidying it produces 404s against production, so a
test pins it.

**4. Idempotency keys are persisted before the request and replayed after process death.**
The convenience form is the SDK-managed, replay-safe one; owning your own key requires
passing `idempotencyKey:` explicitly. That inversion is the point: on Android the easy path
is the one that double-credits.

**5. Playtime is metered the way Android meters it.** `PlaytimeMeter` is a direct port,
cutover arithmetic included, because the two platforms feed the same engagement tables — an
iOS meter that counted idle time slightly differently would show up as a platform difference
and be blamed on players rather than on the meter. 40s idle timeout, ~60s banking, deltas not
totals, persisted before upload, and a 4xx counts as delivered because the server validates
deny-by-default.

**6. An ad cannot hold the game hostage, and cannot over-report itself.** `showInterstitial()`
is bounded by a 90-second failsafe — the same budget as Android's overlay — held in the
*pipeline* rather than only in the overlay, because the pipeline is compiled and tested on
every platform and the overlay is not. If the surface never resolves, the caller resumes and
the surface is torn down. The budget counts **foreground** time only: the commonest reason an
ad is on screen for minutes is that the player tapped it and is reading the advertiser's page,
and a wall-clock bound would fire on exactly that player. In the other direction, `.shown` is
reported only when the forced-view window actually elapsed — an ad dismissed out from under
the player is `.noAd`, never a credited impression.

**7. Persisted state is scoped to the account that created it.** A stable key prevents
double-crediting and does nothing about MIS-crediting. Every log entry records the opaque
`userScope` captured at mint time, and a sweep replays only entries matching the account
signed in now. Without it: player A earns, the process dies, player B signs in on the same
device, and the sweep replays A's operation under B's token — valid token, unseen key, and
the server credits B. A's coins gone, B's inflated, no error anywhere. "Lost win" would have
become "wrong player credited", which is strictly worse than the bug being fixed.

The same rule is why `URLSessionTransport` never uses `URLSession.shared`: `URLCache` keys on
the URL and ignores the Authorization header, and the API sets no `Cache-Control` on
`GET /me/wallet`, so the shared session could serve A's balance to B from cache. The SDK
builds an ephemeral, cache-less, cookie-less session rather than depending on server headers
for a property it can guarantee itself.

## The rule the idempotency log encodes

Because a stable key makes a replay free, the log **resolves an entry only on an outcome it
is certain about, and keeps everything else.** Erring toward keeping costs at most one
redundant request. Erring toward resolving loses a player's coins permanently.

So `.malformedResponse` and `.unauthorized` are NOT treated as decided: an undecodable 200
most likely means the operation applied, and replaying under the same key returns
`applied == false` at zero cost.

Call `reconcile()` after sign-in on launch. It returns what it settled, so the game can
refresh its UI — a win that lands during a silent sweep and never reaches the screen is only
half-fixed.

## Two hosts

| Host | Claimed by | Path |
|---|---|---|
| `hub.godofgaming.online` | the hub app | `/auth` |
| `link.godofgaming.online` | each game | `/launch/<its-own-game-id>` |

Required, not cosmetic. TN3155: a Universal Link with the **same domain as the previous
navigation** does not open the app. On one host the hub-not-installed fallback becomes
Safari at `…/auth` → sign in → `…/launch/<uuid>` → same domain, game never opens, live 120s
credential stranded in the browser. The roles must not cross, and
`LaunchLinkValidator` rejects both crossings with a distinct `.hostRoleMismatch` — separate
from `.wrongHost`, because one is our own misconfiguration and the other is a stranger
linking at us.

Both hosts are ours, so §4.1's vouching argument is untouched: it required the host to be one
GOG serves AASA for, never "exactly one hostname".

## Deployment target: iOS 17.4

A **security** floor, not a compatibility one. `ASWebAuthenticationSession`'s
`.https(host:path:)` callback arrived in iOS 17.4; below it the only callback mechanism is a
custom URL scheme. The hub-not-installed path cannot avoid `ASWebAuthenticationSession` —
Apple's TN3155 documents that a universal link with the **same domain as the previous
navigation** will not open the app, which is exactly the plain-Safari fallback shape. GOG has
no iOS installed base, so the cost today is zero.

## What is deliberately not here

Nothing in this package depends on a decision that is still open. Absent on purpose:

- **AASA and the Associated Domains entitlement.** Blocked on a real Apple Team ID.
  `signInWithGog()` — the whole reverse handoff including `ASWebAuthenticationSession` — IS
  written, and everything around it is tested against a scripted presenter. Only the browser
  presentation needs the entitlement; without it the session refuses to start and the SDK
  throws `.notConfigured` saying exactly that rather than failing obscurely.
- **Sign in with Apple.** Hub-side; App Store review gate for the hub.
- **AdMob in `GogAds`.** An `admob` directive still resolves to `.noAd` with a loud warning,
  exactly as the Unity binding's `GogAds` does. The native interstitial itself is here:
  `GogAdmob.showInterstitial(adUnitId:timeout:)` is the port of android-core's `GogAdmob`
  (monorepo `a67616a`) — same guards, same ordering, same reason tokens. Google Mobile Ads
  stays an optional dependency of the *game*: `GmaRuntimeBackend` probes for it by class name
  and drives its Objective-C surface, so a game without GMA gets `gma_missing`, not a crash.
  Wiring the directive to it is one call, to be made in both bindings together.
- **The hub signing-cert pin (android-core `HubIdentity`).** No iOS counterpart by design:
  iOS cannot inspect another app's signature. Hub authenticity is Universal-Link routing on
  `hub.godofgaming.online`, vouched for by the AASA file.
- **`GogErrorCode.hubNotInstalled` / `.hubVerificationFailed` / `.unsupportedOsVersion` /
  `.adNotConfigured`.** In the contract, deliberately NOT added here: iOS cannot observe the
  first two at all, the 17.4 floor makes the third unreachable, and nothing produces the
  fourth until AdMob lands. A case nothing can produce is a case someone will handle wrongly.

The launch-code delimiter (`#code=` vs `?code=`) is an OPEN DECISION, but it is no longer
blocking: it is a one-line policy on `GogConfiguration`, defaulting to `.fragment`, with the
non-active position rejected as `.codeDeliveredInWrongPosition` rather than quietly accepted.
- **The `initialize()` catalogue check.** Provisionally ratified, held pending the backend
  lane's answer on whether mini games ever get an iOS surface — that answer changes the
  error text.
- **Anything keyed on the catalogue row model**, which is upstream and unanswered.

`GogCoins` takes a `GogSessionProvider` closure rather than owning a session, so Phase 3 slots
in underneath without changing anything here. That closure returns ONE snapshot carrying both
the access token and the opaque `userScope` — deliberately not two closures, because two
independent reads can straddle an account switch and pair one account's token with another's
scope, which is the exact mismatch the scope exists to prevent.

**Phase 3 must supply a `userScope` that is stable per account across sign-out/sign-in,
different between accounts, and not raw PII** (the log is plaintext and backup-eligible; a
stable hash of the account id is the recommended value). The coins layer never interprets it.

## Version square

`GogSDKVersion.value` ships as `0.0.0-unstamped` and is rewritten by the release script. An
unstamped build **warns**; a binding/core **mismatch throws** (contract §1.5, ordinal string
equality, no semver parsing).

The stamping and verification scripts belong in the monorepo's release tooling, not here —
adding a second copy would create exactly the second source of truth §5 warns about. They
must read the four values back from **built artifacts**, not sources: the only reading that
cannot lie.

## Building and testing

```bash
swift build
swift test                      # 243 tests, no network, no simulator, no Mac required
./scripts/selftest.sh           # 31 build-script assertion tests, also anywhere
./scripts/typecheck-ios-shape.sh   # 15 checks: type-check the Apple-only code, on Linux

# macOS + Xcode only:
./scripts/build-xcframework.sh --package-json "<monorepo>/game-sdk/unity/com.gog.sdk/package.json"
./scripts/verify-xcframework.sh dist/GOG.xcframework 0.2.1
```

### 🔴 `typecheck-ios-shape.sh` — and why it exists

Nine `#if canImport(...)` blocks in this package compile to **nothing** on Linux: the ad
overlay, the playtime input hook, the web-auth presenter, the shipping Keychain store, the
CryptoKit hash behind every `userScope`, and `os_log`. `swift build` was green and all 199
tests passed without a single line of any of them being seen by a compiler.

That is not a theoretical gap. The first run of this script found **three real defects**, two of
them hard Swift 6 isolation errors that would have failed the first Xcode build outright:

1. `ASWebAuthPresenterImpl()` — a `@MainActor` initialiser called from `GogIdentity`'s
   nonisolated actor init.
2. `UIDevice.current.systemVersion` — Apple declares `@MainActor class UIDevice`; this ran from
   the playtime actor. Replaced with `ProcessInfo.operatingSystemVersion`, which is nonisolated,
   needs no hop, and returns the same numbers.
3. A missing `import UIKit.UIGestureRecognizerSubclass`. `touchesBegan`/`pressesBegan`/`reset`
   are declared in that submodule, not on `UIGestureRecognizer` — without it all five overrides
   fail with *"does not override any method from its superclass"*, killing the whole input path.

It works by building a shim of the exact Apple API surface these files touch — carrying Apple's
real `@MainActor` annotations, which is the entire point, since isolation is where the bugs
were — and type-checking against it. Signatures were checked against Apple's documentation, not
recalled.

**It proves less than Xcode, and says so.** It does not link, does not run, cannot verify
`@objc` exposability, and cannot see the `UIGestureRecognizerSubclass` import it just taught us
to need. So it self-tests: six canaries prove each guarded region is genuinely being compiled, a
reachability probe proves the guarded *types* resolve, and a separate pass proves every
`#selector` names a real `@objc` method. A harness that cannot fail is not evidence.

The real gate is still `xcodebuild -destination 'generic/platform=iOS'`.

### The build path

`build-xcframework.sh` refuses to run without a version — it never defaults, because a build
that quietly picks a version is worse than one that stops. It stamps
`GogSDKVersion.swift`, archives device-arm64 and simulator-arm64, assembles the XCFramework,
and then **verifies the built artifact**, failing the build on any of:

- a missing or unexpected slice (set equality — an extra slice fails too)
- `x86_64` / `armv7` present, or `arm64` absent
- **a slice built for the wrong platform.** An arm64 binary built for `IOS` sits happily
  inside the simulator slice, passes every `lipo` check, and then fails at install with an
  unrelated-looking error. This is the Unity `baselib.a` trap transposed — architecture alone
  is not sufficient, so the mach-o build platform is asserted too.
- the version constant missing from the **compiled binary**. The Info.plist can say anything;
  `strings` on the binary is the reading that cannot lie, and it is the same move that
  settled the Android version ambiguity by unzipping the `.aar`.

SwiftPM emits either a `.framework` or a static `libGOG.a` depending on how the product
resolves. The script detects which and assembles accordingly rather than assuming — and says
which path it took. If Phase 4 finds Unity prefers a static framework (no embed step, closer
to the `.aar` model), that is a packaging decision to make with a real Unity export in hand.

The assertion logic lives in `scripts/lib/slice-assertions.sh` as pure text-in/result-out
functions, and `scripts/selftest.sh` exercises all of it — including every failure mode —
without macOS. An unrunnable verification script is indistinguishable from a broken one until
the day it matters.
