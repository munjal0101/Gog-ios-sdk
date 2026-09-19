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

# Rewrite the two lines: `value`, and `compiled` — the same version as a StaticString so it
# lands in the binary as text (see GogSDKVersion.swift). Deliberately anchored on the exact
# declarations rather than a loose match, so a future edit that moves either fails here
# instead of silently stamping nothing.
for decl in 'public static let value = "' 'static let compiled: StaticString = "'; do
  grep -q "^    $decl" "$FILE" || {
    echo "FAIL: could not find \`$decl…\` in $FILE — it moved or was renamed" >&2
    exit 1
  }
done
tmp="$(mktemp)"
sed -e 's|^    public static let value = ".*"$|    public static let value = "'"$VERSION"'"|' \
    -e 's|^    static let compiled: StaticString = ".*"$|    static let compiled: StaticString = "'"$VERSION"'"|' \
  "$FILE" > "$tmp"
mv "$tmp" "$FILE"

# Read back BOTH. Stamping that reports success without changing anything is the failure
# mode this guards, and two lines that disagree would be a version square inside one file.
STAMPED="$(sed -n 's|^    public static let value = "\(.*\)"$|\1|p' "$FILE")"
gog_assert_version "$STAMPED" "$VERSION" "GogSDKVersion.swift value" || exit 1
COMPILED="$(sed -n 's|^    static let compiled: StaticString = "\(.*\)"$|\1|p' "$FILE")"
gog_assert_version "$COMPILED" "$VERSION" "GogSDKVersion.swift compiled" || exit 1
