#!/usr/bin/env bash
# Type-check the SDK **as if UIKit and AuthenticationServices were present**, on Linux.
#
# WHY THIS EXISTS
# Three files in this package are wrapped in `#if canImport(UIKit)` / `canImport(
# AuthenticationServices)`. On Linux they compile to nothing, so `swift build` and all 199
# tests pass without a single line of them ever being looked at by a compiler. That is not a
# theoretical gap: the first run of this script found three real defects in them, two of them
# hard Swift 6 isolation errors that would have failed the first Xcode build outright.
#
# It covers EVERY Apple-only branch in the package, not just UIKit: `canImport(Security)`
# (the shipping Keychain store), `canImport(CryptoKit)` (the hash behind every userScope) and
# `canImport(os)` were all equally invisible to `swift build` on Linux.
#
# It works by building a small shim (scripts/ios-shape/shim) that declares the exact Apple API
# surface those files touch — with Apple's real @MainActor annotations, which is the entire
# point, since isolation is where the bugs were — and type-checking the sources against it.
#
# 🔴 WHAT THIS DOES **NOT** PROVE
#   - It is not Xcode. Signatures come from a hand-written shim checked against Apple's
#     documentation, not from the real SDK. A shim that is wrong the same way the code is wrong
#     proves nothing, which is why `--selftest` exists below.
#   - `@objc` and `#selector` need an ObjC runtime Linux does not have, so prepare.py rewrites
#     them. Selector TARGETS are checked separately (--selectors), but @objc EXPOSABILITY is not.
#   - `import UIKit.UIGestureRecognizerSubclass` is a Clang submodule that cannot exist here, so
#     it is stripped. It is REQUIRED on iOS. Only Xcode verifies it is present.
#   - It links nothing and runs nothing.
#
# The real gate remains: xcodebuild -destination 'generic/platform=iOS'
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"; SHAPE="$ROOT/scripts/ios-shape"; WORK="${TMPDIR:-/tmp}/gog-ios-shape.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/out"
fail=0; pass=0
say() { printf '%s\n' "$*"; }
ok()  { pass=$((pass+1)); say "  ✅ $*"; }
bad() { fail=$((fail+1)); say "  ❌ $*"; }

command -v swiftc >/dev/null || { say "swiftc not found"; exit 127; }

say "── building the shim ──"
for m in QuartzCore UIKit AuthenticationServices Security CryptoKit os; do
  if swiftc -emit-module -swift-version 6 -module-name "$m" -I "$WORK/out" \
       "$SHAPE/shim/$m.swift" -emit-module-path "$WORK/out/$m.swiftmodule" 2>"$WORK/$m.err"; then
    ok "$m"
  else bad "$m"; sed 's/^/     /' "$WORK/$m.err" | head -10; fi
done

say "── type-checking every source with UIKit present ──"
python3 "$SHAPE/prepare.py" "$ROOT/Sources/GOG" "$WORK/src" >/dev/null
if swiftc -typecheck -swift-version 6 -module-name GOG -I "$WORK/out" \
     $(find "$WORK/src" -name '*.swift' | sort) 2>"$WORK/tc.err"; then
  ok "all sources type-check under Swift 6"
else
  bad "type-check failed"; sed "s|$WORK/src/|     |" "$WORK/tc.err" | grep -E "error:" | head -25
fi

if [[ "${1:-}" == "--selftest" || "${1:-}" == "" ]]; then
  say "── selftest A: guarded TYPES are reachable (proves those branches compiled) ──"
  python3 "$SHAPE/prepare.py" "$ROOT/Sources/GOG" "$WORK/src" >/dev/null
  cp "$SHAPE/reachability.swift" "$WORK/src/__reachability.swift"
  if swiftc -typecheck -swift-version 6 -module-name GOG -I "$WORK/out" \
       $(find "$WORK/src" -name '*.swift' | sort) 2>"$WORK/reach.err"; then
    ok "KeychainSecureStore / UIKitAdPresenter / ASWebAuthPresenterImpl all resolve"
  else
    bad "a guarded branch is NOT being compiled"; grep -E "error:" "$WORK/reach.err" | head -5
  fi

  say "── selftest B: inject an error into each guarded region; each MUST be caught ──"
  canary() {
    python3 "$SHAPE/prepare.py" "$ROOT/Sources/GOG" "$WORK/src" >/dev/null
    python3 "$SHAPE/inject-canary.py" "$WORK/src/$1" "$2"
    swiftc -typecheck -swift-version 6 -module-name GOG -I "$WORK/out" \
      $(find "$WORK/src" -name '*.swift' | sort) >"$WORK/canary.out" 2>&1 || true
    if grep -q "cannot convert value of type 'String'" "$WORK/canary.out"
    then ok "canary caught: $1"
    else bad "canary NOT caught: $1 — that branch is not being checked"; fi
  }
  canary Internal/Crypto/SHA256.swift    '#if canImport(CryptoKit)'
  canary Internal/GogLog.swift           '#if canImport(os)'
  canary Ads/UIKitAdPresenter.swift      '#if canImport(UIKit) && !os(watchOS)'
  canary Playtime/PlaytimeAutoHook.swift '#if canImport(UIKit)'
  canary Identity/WebAuthPresenter.swift '#if canImport(AuthenticationServices) && canImport(UIKit)'
  canary Identity/SecureStore.swift      '#if canImport(Security)'
  python3 "$SHAPE/prepare.py" "$ROOT/Sources/GOG" "$WORK/src" >/dev/null
fi

say "── selectors resolve to @objc methods (the harness cannot check this itself) ──"
if python3 "$SHAPE/check-selectors.py" "$ROOT/Sources/GOG"; then ok "every #selector resolves"
else bad "unresolved selector - a runtime crash, not a compile error"; fi

say ""
say "ios-shape: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
