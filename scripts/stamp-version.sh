#!/usr/bin/env bash
# Stamp the Swift corner of the version square into the generated constant.
#
# Usage: scripts/stamp-version.sh <X.Y.Z>
#
# Contract §1.5: this value must equal package.json's "version", the generated C# constant,
# and the .aar's BuildConfig.SDK_VERSION, by ORDINAL STRING EQUALITY. Never a semver compare.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/slice-assertions.sh

VERSION="${1:-${GOG_SDK_VERSION:-}}"
[[ -n "$VERSION" ]] || { echo "usage: $0 <X.Y.Z>   (or set GOG_SDK_VERSION)" >&2; exit 2; }
gog_assert_version_format "$VERSION" || exit 1

FILE="Sources/GOG/GogSDKVersion.swift"
[[ -f "$FILE" ]] || { echo "FAIL: $FILE not found" >&2; exit 1; }

# Rewrite the one line. Deliberately anchored on the exact declaration rather than a loose
# match, so a future edit that moves it fails here instead of silently stamping nothing.
grep -q '^    public static let value = "' "$FILE" || {
  echo "FAIL: could not find the version declaration in $FILE — it moved or was renamed" >&2
  exit 1
}
tmp="$(mktemp)"
sed 's|^    public static let value = ".*"$|    public static let value = "'"$VERSION"'"|' \
  "$FILE" > "$tmp"
mv "$tmp" "$FILE"

# Read back. Stamping that reports success without changing anything is the failure mode
# this guards.
STAMPED="$(sed -n 's|^    public static let value = "\(.*\)"$|\1|p' "$FILE")"
gog_assert_version "$STAMPED" "$VERSION" "GogSDKVersion.swift" || exit 1
