#!/usr/bin/env bash
# Pure assertion functions for XCFramework verification.
#
# They take TEXT (the output of lipo / vtool / plutil) rather than running those tools, for
# one reason: the tools are macOS-only, so keeping the logic separate is the only way this
# logic gets tested at all. scripts/selftest.sh exercises every function below against good
# and bad fixtures, and runs anywhere.
#
# Every function prints a specific failure and returns 1. None of them return 0 on "couldn't
# tell" — an unparseable input is a failure, because the whole point is that a wrong slice
# must not be able to look like a right one.

gog_fail() { printf 'FAIL: %s\n' "$1" >&2; return 1; }
gog_ok()   { printf 'ok:   %s\n' "$1"; return 0; }

# ── architectures ────────────────────────────────────────────────────────────
# gog_assert_arch <lipo-output> <required-arch> [forbidden-arch ...]
#
# Handles both lipo forms:
#   "Non-fat file: GOG is architecture: arm64"
#   "Architectures in the fat file: GOG are: arm64 x86_64"
gog_assert_arch() {
  local out="$1" required="$2"; shift 2
  local archs=""

  if [[ "$out" == *"is architecture:"* ]]; then
    archs="${out##*is architecture: }"
  elif [[ "$out" == *"are:"* ]]; then
    archs="${out##*are: }"
  else
    gog_fail "could not parse lipo output: '${out}'"; return 1
  fi
  archs="$(printf '%s' "$archs" | tr -s ' ' ' ' | sed 's/^ *//; s/ *$//')"

  [[ " $archs " == *" $required "* ]] || {
    gog_fail "required arch '$required' missing; found: '$archs'"; return 1; }

  local forbidden
  for forbidden in "$@"; do
    [[ " $archs " == *" $forbidden "* ]] && {
      gog_fail "forbidden arch '$forbidden' present; found: '$archs'"; return 1; }
  done
  gog_ok "arch '$archs' contains '$required'"
}

# ── platform ─────────────────────────────────────────────────────────────────
# gog_assert_platform <vtool-or-otool-output> <IOS|IOSSIMULATOR>
#
# THE UNITY TRAP, TRANSPOSED. A Unity export defaulting to x86_64 produced an app the arm64
# simulator refused to install, while an arm64 build of the same export failed to link — a
# full day lost because nothing asserted the slice before the compile. An XCFramework has the
# identical hazard in a nastier form: an arm64 binary built for platform IOS looks correct to
# `lipo` and will sit happily inside the simulator slice, then fail at install or at runtime
# with an unrelated-looking error. Architecture alone is NOT sufficient; the platform must be
# asserted too.
#
# Accepts symbolic names and the raw mach-o constants (PLATFORM_IOS=2, PLATFORM_IOSSIMULATOR=7),
# because vtool prints one or the other depending on toolchain version.
gog_assert_platform() {
  local out="$1" expected="$2" line found
  line="$(printf '%s\n' "$out" | grep -E '^[[:space:]]*platform[[:space:]]' | head -1 || true)"
  [[ -n "$line" ]] || { gog_fail "no 'platform' line in build-version output"; return 1; }
  found="$(printf '%s' "$line" | awk '{print $2}')"

  case "$found" in
    IOSSIMULATOR|7) found="IOSSIMULATOR" ;;
    IOS|2)          found="IOS" ;;
    *)              gog_fail "unrecognised platform '$found'"; return 1 ;;
  esac

  [[ "$found" == "$expected" ]] || {
    gog_fail "platform is '$found', expected '$expected' — an arm64 binary built for the "\
"wrong platform passes every lipo check and still fails at install"; return 1; }
  gog_ok "platform '$found'"
}

# ── slice inventory ──────────────────────────────────────────────────────────
# gog_assert_slice_set <actual-newline-list> <expected-newline-list>
# Exact set equality: a MISSING slice and an UNEXPECTED extra slice are both failures.
gog_assert_slice_set() {
  local actual expected
  actual="$(printf '%s\n' "$1" | sed '/^[[:space:]]*$/d' | sort)"
  expected="$(printf '%s\n' "$2" | sed '/^[[:space:]]*$/d' | sort)"
  if [[ "$actual" != "$expected" ]]; then
    gog_fail "slice set mismatch
  expected: $(printf '%s' "$expected" | tr '\n' ' ')
  actual:   $(printf '%s' "$actual" | tr '\n' ' ')"
    return 1
  fi
  gog_ok "slices: $(printf '%s' "$actual" | tr '\n' ' ')"
}

# ── version square ───────────────────────────────────────────────────────────
# gog_assert_version <value-read-from-artifact> <expected> <what>
gog_assert_version() {
  local actual="$1" expected="$2" what="$3"
  [[ -n "$actual" ]] || { gog_fail "$what: no version found in the built artifact"; return 1; }
  # ORDINAL STRING EQUALITY, per contract §1.5. No semver parsing — a parser silently matches
  # "0.2.1" to "0.2.1.0", which is the exact class of bug the handshake exists to catch.
  [[ "$actual" == "$expected" ]] || {
    gog_fail "$what: artifact says '$actual', expected '$expected'"; return 1; }
  gog_ok "$what: '$actual'"
}

# gog_assert_version_in_binary <strings-output> <expected>
# The reading that cannot lie: the constant compiled INTO the binary, not a plist beside it.
# This is the same check that resolved the Android version ambiguity — the only value that
# could not be stale was BuildConfig.SDK_VERSION pulled out of the compiled class.
gog_assert_version_in_binary() {
  local out="$1" expected="$2"
  printf '%s\n' "$out" | grep -qxF "$expected" || {
    gog_fail "the version constant '$expected' is not present in the compiled binary — the "\
"Info.plist can say anything; this is what actually ships"; return 1; }
  gog_ok "binary contains the version constant '$expected'"
}

# ── version format ───────────────────────────────────────────────────────────
gog_assert_version_format() {
  local v="$1"
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] || {
    gog_fail "version '$v' is not X.Y.Z"; return 1; }
  [[ "$v" != "0.0.0-unstamped" ]] || {
    gog_fail "refusing to build with the unstamped placeholder version"; return 1; }
  gog_ok "version '$v'"
}
