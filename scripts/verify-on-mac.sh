#!/usr/bin/env bash
# The real gate. Everything else in this repo is a rehearsal for this command.
#
#   ./scripts/verify-on-mac.sh
#
# Run on a Mac with Xcode. Needs no Apple Developer account, no Team ID, no certificate and
# no device — it compiles for a generic iOS target with signing off.
#
# WHAT ONLY THIS CAN DO. Nine `#if canImport(...)` blocks compile to NOTHING on Linux, so
# `swift build` plus a green test suite never touch them. UIKit, AuthenticationServices,
# Security, CryptoKit and os are all absent there. `./scripts/typecheck-ios-shape.sh` checks
# them against a hand-written shim on any machine and found three genuine bugs doing so —
# but a shim is written from documentation, and documentation is not a compiler.
#
# LOGS. Everything lands in .build/gog-verify-logs/ (already gitignored, so this leaves the
# working tree exactly as it found it). Claude reads that directory directly through the
# connected folder — you do not need to copy anything back.
set -uo pipefail
cd "$(dirname "$0")/.." || { echo "cannot cd to repo root"; exit 1; }
ROOT="$PWD"

LOGS="$ROOT/.build/gog-verify-logs"
rm -rf "$LOGS"; mkdir -p "$LOGS"

pass=0; fail=0; skip=0
step() { printf '\n══ %s ══\n' "$*"; }
ok()   { pass=$((pass+1)); printf '  PASS  %s\n' "$*"; echo "PASS  $*" >> "$LOGS/SUMMARY.txt"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$*"; echo "FAIL  $*" >> "$LOGS/SUMMARY.txt"; }
note() { skip=$((skip+1)); printf '  SKIP  %s\n' "$*"; echo "SKIP  $*" >> "$LOGS/SUMMARY.txt"; }

# Show the first real compiler errors on screen; the full log is always on disk.
errors_from() { grep -E "error:|error " "$1" 2>/dev/null | head -12 | sed 's/^/        /'; }

# ─────────────────────────────────────────────────────────────────────────────
step "0/6  environment"
# ─────────────────────────────────────────────────────────────────────────────
{ echo "date:    $(date)"; echo "uname:   $(uname -srm)"
  sw_vers 2>/dev/null; xcodebuild -version 2>/dev/null
  echo "sdk:     $(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null)"
  echo "swift:   $(swift --version 2>&1 | head -1)"; } > "$LOGS/env.txt" 2>&1
cat "$LOGS/env.txt"

if ! command -v xcodebuild >/dev/null; then
  echo
  echo "xcodebuild not found. Either Xcode is not installed, or the command line tools are"
  echo "pointed at the CLT-only path. Fix with:"
  echo "    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  exit 127
fi

# The 17.4 deployment floor is a SECURITY floor: ASWebAuthenticationSession's
# .https(host:path:) callback did not exist before it. Building against an older SDK fails
# deep inside WebAuthPresenter with a confusing message, so say it plainly here instead.
SDKV="$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null)"
if [[ -n "$SDKV" ]]; then
  if [[ "$(printf '%s\n17.4\n' "$SDKV" | sort -V | head -1)" == "17.4" ]]; then
    ok "iOS SDK $SDKV (>= 17.4, the ASWebAuthenticationSession .https callback floor)"
  else
    bad "iOS SDK $SDKV is below the 17.4 floor — update Xcode; nothing below will build"
  fi
else
  bad "no iphoneos SDK found — Xcode is installed but has no iOS platform"
fi

if xcodebuild -list 2>"$LOGS/schemes.txt" | tee -a "$LOGS/schemes.txt" | grep -qx '        GOG'; then
  ok "scheme GOG resolves"
else
  bad "scheme GOG not found — see .build/gog-verify-logs/schemes.txt for what does exist"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "1/6  compile for a real iOS device target"
#   The first compile of UIKitAdPresenter / PlaytimeAutoHook / WebAuthPresenter and every
#   UIKit-guarded block against the REAL frameworks.
# ─────────────────────────────────────────────────────────────────────────────
xcodebuild -scheme GOG -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build > "$LOGS/1-device-build.log" 2>&1
if grep -q "BUILD SUCCEEDED" "$LOGS/1-device-build.log"; then
  ok "device build"
else
  bad "device build"; errors_from "$LOGS/1-device-build.log"
fi
printf '        warnings: %s\n' "$(grep -c 'warning:' "$LOGS/1-device-build.log")"

# Negative control for the step above. If a guard excluded these files, the build would
# succeed while proving nothing at all — which is the exact failure this whole gate exists
# to catch. Informational, because xcodebuild's log format varies by Xcode version.
step "1b   were the never-before-compiled files actually IN that compile?"
for f in UIKitAdPresenter PlaytimeAutoHook WebAuthPresenter SecureStore ForegroundClock; do
  if grep -q "$f\.swift" "$LOGS/1-device-build.log"; then printf '        seen      %s.swift\n' "$f"
  else printf '        NOT SEEN  %s.swift  <- check this\n' "$f"; fi
done

# ─────────────────────────────────────────────────────────────────────────────
step "2/6  compile for the simulator"
# ─────────────────────────────────────────────────────────────────────────────
xcodebuild -scheme GOG -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build > "$LOGS/2-sim-build.log" 2>&1
if grep -q "BUILD SUCCEEDED" "$LOGS/2-sim-build.log"; then ok "simulator build"
else bad "simulator build"; errors_from "$LOGS/2-sim-build.log"; fi

# ─────────────────────────────────────────────────────────────────────────────
step "3/6  test suite on the host (macOS)"
#   Not a repeat of the Linux run. macOS HAS Security, CryptoKit and os — so SecureStore's
#   Keychain path, SHA256's CryptoKit branch and GogLog's os.Logger branch are compiled here
#   for the first time by a real compiler. macOS has no UIKit, so those stay guarded out.
# ─────────────────────────────────────────────────────────────────────────────
swift test > "$LOGS/3-host-tests.log" 2>&1
if grep -qE "with 0 failures" "$LOGS/3-host-tests.log"; then
  ok "$(grep -oE 'Executed [0-9]+ tests, with [0-9]+ failures' "$LOGS/3-host-tests.log" | tail -1)"
else
  bad "host tests"
  grep -E "error:|XCTAssert|failed" "$LOGS/3-host-tests.log" | head -12 | sed 's/^/        /'
fi

# ─────────────────────────────────────────────────────────────────────────────
step "4/6  test suite ON THE SIMULATOR — the first time any of this RUNS on Apple"
#   Everything above proves the code compiles. This is the only step that executes it with
#   real UIKit behind it. Skipped cleanly if no simulator runtime is installed; a skip is
#   not a pass and is reported as its own category.
# ─────────────────────────────────────────────────────────────────────────────
SIM="$(xcrun simctl list devices available 2>/dev/null \
        | sed -n 's/^ *\(iPhone [^(]*\)(.*/\1/p' | sed 's/ *$//' | tail -1)"
if [[ -z "$SIM" ]]; then
  note "no iPhone simulator installed — Xcode > Settings > Platforms to add one"
else
  echo "        using simulator: $SIM"
  xcodebuild test -scheme GOG -destination "platform=iOS Simulator,name=$SIM" \
    CODE_SIGNING_ALLOWED=NO > "$LOGS/4-sim-tests.log" 2>&1
  if grep -q "TEST SUCCEEDED" "$LOGS/4-sim-tests.log"; then
    ok "simulator tests on $SIM — the SDK has now actually run on Apple"
  elif grep -qE "Scheme GOG is not currently configured for the test action" "$LOGS/4-sim-tests.log"; then
    note "scheme has no test action for the simulator destination"
  else
    bad "simulator tests"
    grep -E "error:|XCTAssert|failed" "$LOGS/4-sim-tests.log" | head -12 | sed 's/^/        /'
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
step "5/6  the XCFramework, end to end"
#   build-xcframework.sh calls stamp-version.sh, which REWRITES
#   Sources/GOG/GogSDKVersion.swift. That would leave your tree dirty with a version you did
#   not ask for, so the original bytes are saved and restored on every exit path, including
#   Ctrl-C. This script must leave the working tree exactly as it found it.
# ─────────────────────────────────────────────────────────────────────────────
VERSIONED_FILE="Sources/GOG/GogSDKVersion.swift"
cp "$VERSIONED_FILE" "$LOGS/GogSDKVersion.swift.orig"
restore_version() {
  if [[ -f "$LOGS/GogSDKVersion.swift.orig" ]]; then
    cp "$LOGS/GogSDKVersion.swift.orig" "$ROOT/$VERSIONED_FILE"
  fi
}
trap restore_version EXIT INT TERM

# 0.2.1 is what com.gog.sdk/package.json says today — the version square's source of truth.
# Override with GOG_SDK_VERSION if the UPM package has moved on.
VERSION="${GOG_SDK_VERSION:-0.2.1}"
./scripts/build-xcframework.sh --version "$VERSION" > "$LOGS/5-xcframework.log" 2>&1
if grep -q "^Built dist/GOG.xcframework @" "$LOGS/5-xcframework.log"; then
  ok "xcframework @ $VERSION"
  grep -E "checksum|Built " "$LOGS/5-xcframework.log" | sed 's/^/        /'
else
  bad "xcframework"; tail -15 "$LOGS/5-xcframework.log" | sed 's/^/        /'
fi

restore_version
# Byte-for-byte, NOT a grep for the unstamped literal. That grep passes unconditionally,
# because line 24 of the file is `isUnstamped: Bool { value == "0.0.0-unstamped" }` — the
# string is present whatever the constant says. A check that cannot fail is worse than no
# check, because it reads as evidence.
if cmp -s "$LOGS/GogSDKVersion.swift.orig" "$VERSIONED_FILE"; then
  ok "working tree restored, byte for byte"
else
  bad "$VERSIONED_FILE was NOT restored — restore it with:
        cp .build/gog-verify-logs/GogSDKVersion.swift.orig $VERSIONED_FILE"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "6/6  the shim harness, for comparison"
#   Runs on the Mac too. If the shim passes and the real build failed, the difference is a
#   place where the shim lies — worth knowing precisely, because that is the harness's only
#   job and a silent gap in it is how the next bug gets through.
# ─────────────────────────────────────────────────────────────────────────────
./scripts/typecheck-ios-shape.sh > "$LOGS/6-shim.log" 2>&1
if grep -qE "0 failed" "$LOGS/6-shim.log"; then ok "shim harness agrees"
else note "shim harness reported failures — see 6-shim.log"; fi

# ─────────────────────────────────────────────────────────────────────────────
printf '\n════════════════════════════════════════════════════════════\n'
printf 'verify-on-mac: %s passed, %s failed, %s skipped\n' "$pass" "$fail" "$skip"
printf 'full logs: .build/gog-verify-logs/\n'
printf '════════════════════════════════════════════════════════════\n'
{ echo; echo "totals: $pass passed, $fail failed, $skip skipped"; } >> "$LOGS/SUMMARY.txt"

if [[ $fail -eq 0 ]]; then
  printf '\nThe blocks that no compiler had ever seen now compile against the real frameworks.\n'
  printf 'That closes the gap between "the tests are green" and "this builds".\n'
  if grep -q "the SDK has now actually run on Apple" "$LOGS/SUMMARY.txt" 2>/dev/null; then
    printf 'And it ran. What remains unproven is only what needs real hardware and live hosts:\n'
    printf 'Universal Links, the Keychain on a real device, and the hub sign-in round trip.\n'
  else
    printf 'Still unproven, and only a simulator or device can prove it: that it RUNS.\n'
  fi
fi
[[ $fail -eq 0 ]]
