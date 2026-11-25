#!/usr/bin/env bash
# Source-drift guard for the privacy manifest. Runs anywhere (no Xcode).
#
# Usage: scripts/check-privacy-manifest.sh [sources-dir] [manifest]
#
# Scans Swift sources for Apple's required-reason APIs and fails if one is used without its
# category being declared in PrivacyInfo.xcprivacy. Comment lines are ignored, so prose that
# mentions an API does not count as a use. The point: adding e.g. a file-timestamp read next
# quarter breaks this check on the spot, not an App Store upload weeks later.
set -uo pipefail
cd "$(dirname "$0")/.."

SRC="${1:-Sources/GOG}"
MANIFEST="${2:-Sources/GOG/PrivacyInfo.xcprivacy}"

[[ -f "$MANIFEST" ]] || { echo "FAIL: no privacy manifest at $MANIFEST" >&2; exit 1; }
manifest_text="$(cat "$MANIFEST")"

# category | extended regex of API uses
RULES=$'NSPrivacyAccessedAPICategoryUserDefaults|UserDefaults\nNSPrivacyAccessedAPICategorySystemBootTime|systemUptime|mach_absolute_time\nNSPrivacyAccessedAPICategoryFileTimestamp|creationDate|modificationDate|fileModificationDate|attributesOfItem|getattrlist\nNSPrivacyAccessedAPICategoryDiskSpace|volumeAvailableCapacity|systemFreeSize|statfs\nNSPrivacyAccessedAPICategoryActiveKeyboards|activeInputModes'

code_only() {
  # Strip // and /// comment lines (leading whitespace allowed); keep everything else.
  find "$SRC" -name '*.swift' -print0 | xargs -0 grep -nE "$1" 2>/dev/null \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true
}

rc=0
while IFS= read -r rule; do
  category="${rule%%|*}"; pattern="${rule#*|}"
  uses="$(code_only "$pattern")"
  [[ -z "$uses" ]] && continue
  if printf '%s' "$manifest_text" | grep -q "$category"; then
    echo "ok:   $category declared ($(printf '%s\n' "$uses" | wc -l | tr -d ' ') use(s))"
  else
    echo "FAIL: $category used but NOT declared in $MANIFEST:" >&2
    printf '%s\n' "$uses" | head -5 | sed 's/^/        /' >&2
    rc=1
  fi
done <<< "$RULES"

if [[ $rc -eq 0 ]]; then echo "privacy manifest covers every required-reason API in $SRC"; fi
exit $rc
