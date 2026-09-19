#!/usr/bin/env bash
# Build the GOG iOS SDK as ONE XCFramework — the single artifact that goes through both
# distribution doors (Unity UPM Runtime/Plugins/iOS/, and SPM binaryTarget).
#
# Usage:
#   scripts/build-xcframework.sh --version 0.2.1
#   scripts/build-xcframework.sh --package-json "/path/to/com.gog.sdk/package.json"
#
# macOS + Xcode required. Fails loudly rather than producing a plausible-looking artifact.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/slice-assertions.sh

SCHEME="GOG"
OUT="dist"
DEPLOYMENT_TARGET="17.4"     # matches Package.swift; see GogHosts / the 17.4 decision
VERSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)      VERSION="$2"; shift 2 ;;
    --package-json) VERSION="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$2" | head -1)"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
VERSION="${VERSION:-${GOG_SDK_VERSION:-}}"

# NEVER default. An unstamped or guessed version is exactly what the version square exists to
# make impossible, and a build that quietly picks one is worse than a build that refuses.
[[ -n "$VERSION" ]] || {
  echo "FAIL: no version. Pass --version X.Y.Z, or --package-json <path to the UPM" >&2
  echo "      package.json, which is the source of truth>, or set GOG_SDK_VERSION." >&2
  exit 2
}
gog_assert_version_format "$VERSION"

for tool in xcodebuild lipo vtool strings; do
  command -v "$tool" >/dev/null || { echo "FAIL: '$tool' not found — macOS + Xcode CLT required" >&2; exit 1; }
done

echo "══ stamping $VERSION ══"
scripts/stamp-version.sh "$VERSION"

rm -rf "$OUT/archives" "$OUT/derived" "$OUT/$SCHEME.xcframework" "$OUT/$SCHEME.xcframework.zip"
mkdir -p "$OUT/archives"

# 🔴 Built UNSIGNED, deliberately — and this is what keeps the whole build off the critical
# path for an Apple Developer account. An XCFramework is signed by whoever embeds it: the
# consuming app re-signs everything inside its bundle at build time, so a signature here buys
# authenticity for the download and nothing for the running app. Requiring one would mean this
# script could not run until a Team ID existed, which is a dependency worth not having.
echo "══ archiving ══"
# Two slices only: device arm64 and simulator arm64. x86_64 simulator is deliberately NOT
# built — add it only if a partner is actually on an Intel Mac, and then assert it, rather
# than carrying a slice nobody uses.
#
# 🔴 `-alias-module-names-in-module-interface` is REQUIRED, not tuning. The module is named
# `GOG` and so is its public facade class. A library-evolution build emits a .swiftinterface
# that spells every type fully qualified — `GOG.GogAds` — and inside that file `GOG` resolves
# to the CLASS, not the module, so interface verification fails with "'GogAds' is not a member
# type of class 'GOG.GOG'" and the archive aborts. The flag makes the compiler write the
# module name as an alias that cannot collide. Renaming the class would break the frozen
# public surface; this fixes the artifact instead.
archive() {
  local dest="$1" name="$2"
  xcodebuild archive \
    -scheme "$SCHEME" \
    -destination "$dest" \
    -archivePath "$OUT/archives/$name" \
    -derivedDataPath "$OUT/derived/$name" \
    -configuration Release \
    IPHONEOS_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$VERSION" \
    SKIP_INSTALL=NO \
    BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
    OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -alias-module-names-in-module-interface' \
    ARCHS=arm64 \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO
}
archive "generic/platform=iOS"           device
archive "generic/platform=iOS Simulator" simulator

echo "══ assembling ══"
# SwiftPM emits either a .framework or a static library depending on how the product
# resolves. Detect rather than assume — guessing here is how you get a script that works on
# one machine and silently produces nothing on another.
args=()
for name in device simulator; do
  arch_dir="$OUT/archives/$name.xcarchive"
  fw="$(find "$arch_dir" -type d -name "$SCHEME.framework" | head -1)"
  lib="$(find "$arch_dir" -type f -name "lib$SCHEME.a" | head -1)"
  if [[ -n "$fw" ]]; then
    # Stamp the plist explicitly. MARKETING_VERSION is passed above, but SwiftPM-generated
    # targets do not always wire it through, and the verify step reads the artifact — so set
    # it rather than hoping.
    plist="$fw/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$plist" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$plist"
    # SwiftPM-built frameworks come out WITHOUT Modules/: xcodebuild leaves GOG.swiftmodule
    # (the .swiftinterface a library-evolution build produced) in the build products. Unity
    # does not need it — it calls the C ABI in Bridge/GogUnityBridge.swift — but a native Swift
    # consumer on the SPM door cannot `import GOG` without it, so it goes in.
    mod="$(find "$OUT/derived/$name" -type d -name "$SCHEME.swiftmodule" -path "*BuildProductsPath*" | head -1)"
    if [[ -n "$mod" ]]; then
      mkdir -p "$fw/Modules" && cp -R "$mod" "$fw/Modules/"
    else
      echo "FAIL: no $SCHEME.swiftmodule in the $name build products — the SPM door could not import this" >&2
      exit 1
    fi
    args+=(-framework "$fw")
    echo "  $name: framework (+ Modules/$SCHEME.swiftmodule)"
  elif [[ -n "$lib" ]]; then
    hdrs="$(find "$arch_dir" -type d -name include | head -1)"
    args+=(-library "$lib"); [[ -n "$hdrs" ]] && args+=(-headers "$hdrs")
    echo "  $name: static library (no Info.plist; the compiled-in constant is the version authority)"
  else
    echo "FAIL: $name archive contains neither $SCHEME.framework nor lib$SCHEME.a" >&2
    exit 1
  fi
done

xcodebuild -create-xcframework "${args[@]}" -output "$OUT/$SCHEME.xcframework"

echo "══ verifying the BUILT ARTIFACT ══"
# Not optional, and not advisory. If this fails the build fails, so a wrong or missing slice
# cannot leave the machine looking like a good one.
scripts/verify-xcframework.sh "$OUT/$SCHEME.xcframework" "$VERSION"

echo "══ packaging ══"
( cd "$OUT" && zip -qry "$SCHEME.xcframework.zip" "$SCHEME.xcframework" )
echo -n "SPM binaryTarget checksum: "
swift package compute-checksum "$OUT/$SCHEME.xcframework.zip"
echo
echo "Built $OUT/$SCHEME.xcframework @ $VERSION"
echo "Next: drop it at Runtime/Plugins/iOS/ in the UPM package, and use the checksum above"
echo "      for the SPM binaryTarget."
