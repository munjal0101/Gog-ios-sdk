#!/usr/bin/env bash
# Verify a BUILT XCFramework. macOS + Xcode command line tools required.
#
# Usage: scripts/verify-xcframework.sh <path/to/GOG.xcframework> <X.Y.Z>
#
# Every assertion reads the ARTIFACT, never the source. That distinction is the whole point:
# a checker that reads Package.swift and Sources/ verifies the generator's intent, not what
# actually ships. The Android version ambiguity was only settled by unzipping the .aar and
# pulling BuildConfig.SDK_VERSION out of the compiled class; this is the same move.
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/slice-assertions.sh

XC="${1:-}"; VERSION="${2:-}"
[[ -n "$XC" && -n "$VERSION" ]] || { echo "usage: $0 <GOG.xcframework> <X.Y.Z>" >&2; exit 2; }
[[ -d "$XC" ]] || { echo "FAIL: no such xcframework: $XC" >&2; exit 1; }

EXPECTED_SLICES=$'ios-arm64\nios-arm64-simulator'
rc=0

echo "── slice inventory ──"
ACTUAL_SLICES="$(find "$XC" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort)"
gog_assert_slice_set "$ACTUAL_SLICES" "$EXPECTED_SLICES" || rc=1

for slice in $ACTUAL_SLICES; do
  echo "── $slice ──"
  case "$slice" in
    *-simulator) want_platform="IOSSIMULATOR" ;;
    *)           want_platform="IOS" ;;
  esac

  # Framework or static library — handle both rather than assuming which one SwiftPM emitted.
  bin="$(find "$XC/$slice" -type f \( -name GOG -o -name 'libGOG.a' \) -perm -u+r | head -1)"
  [[ -n "$bin" ]] || { gog_fail "$slice: no GOG binary found"; rc=1; continue; }
  echo "      binary: ${bin#"$XC/"}"

  gog_assert_arch "$(lipo -info "$bin" 2>&1)" arm64 x86_64 armv7 || rc=1
  gog_assert_platform "$(vtool -show-build-version "$bin" 2>&1)" "$want_platform" || rc=1

  # The version in the compiled binary. This is the reading that cannot lie.
  gog_assert_version_in_binary "$(strings -a "$bin" 2>/dev/null)" "$VERSION" || rc=1

  # And the Info.plist, when there is one (framework packaging only).
  plist="$(find "$XC/$slice" -maxdepth 3 -name Info.plist -path '*GOG.framework*' | head -1)"
  if [[ -n "$plist" ]]; then
    got="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null || true)"
    gog_assert_version "$got" "$VERSION" "$slice Info.plist" || rc=1
  else
    echo "note: $slice is static-library packaged (no Info.plist); the binary check above is"
    echo "      the version authority for this slice."
  fi
done

echo
if [[ $rc -eq 0 ]]; then echo "XCFramework VERIFIED: $XC @ $VERSION"; else echo "XCFramework FAILED verification" >&2; fi
exit $rc
