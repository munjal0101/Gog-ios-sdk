#!/usr/bin/env bash
# Exercises every assertion in lib/slice-assertions.sh against real tool output and against
# each way it can go wrong. Runs anywhere — no Xcode, no macOS, no artifact.
#
# It exists because build-xcframework.sh cannot run outside macOS, and an unrunnable
# verification script is indistinguishable from a broken one until the day it matters.
set -uo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib/slice-assertions.sh
source lib/slice-assertions.sh

pass=0; fail=0
expect_pass() { if "$@" >/dev/null 2>&1; then pass=$((pass+1)); else fail=$((fail+1)); echo "  UNEXPECTED FAIL: $*"; fi; }
expect_fail() { if "$@" >/dev/null 2>&1; then fail=$((fail+1)); echo "  UNEXPECTED PASS: $1 ..."; else pass=$((pass+1)); fi; }

echo "── arch ──"
expect_pass gog_assert_arch "Non-fat file: GOG is architecture: arm64" arm64 x86_64
expect_pass gog_assert_arch "Architectures in the fat file: GOG are: arm64 x86_64" arm64
expect_fail gog_assert_arch "Architectures in the fat file: GOG are: arm64 x86_64" arm64 x86_64
expect_fail gog_assert_arch "Non-fat file: GOG is architecture: x86_64" arm64
expect_fail gog_assert_arch "Non-fat file: GOG is architecture: armv7" arm64
expect_fail gog_assert_arch "some unrelated garbage" arm64

echo "── platform (the Unity trap, transposed) ──"
SIM_OK=$'GOG:\nLoad command 10\n      cmd LC_BUILD_VERSION\n  cmdsize 32\n platform IOSSIMULATOR\n    minos 17.4'
DEV_OK=$'GOG:\n      cmd LC_BUILD_VERSION\n platform IOS\n    minos 17.4'
NUMERIC_SIM=$'GOG:\n platform 7\n    minos 17.4'
NUMERIC_DEV=$'GOG:\n platform 2\n    minos 17.4'
expect_pass gog_assert_platform "$SIM_OK" IOSSIMULATOR
expect_pass gog_assert_platform "$DEV_OK" IOS
expect_pass gog_assert_platform "$NUMERIC_SIM" IOSSIMULATOR
expect_pass gog_assert_platform "$NUMERIC_DEV" IOS
# The exact failure this whole check exists for: arm64, right arch, WRONG platform.
expect_fail gog_assert_platform "$DEV_OK" IOSSIMULATOR
expect_fail gog_assert_platform "$SIM_OK" IOS
expect_fail gog_assert_platform $'GOG:\n platform MACOS' IOS
expect_fail gog_assert_platform $'GOG:\n no build version here' IOS

echo "── slice inventory ──"
BOTH=$'ios-arm64\nios-arm64-simulator'
expect_pass gog_assert_slice_set "$BOTH" "$BOTH"
expect_pass gog_assert_slice_set $'ios-arm64-simulator\nios-arm64' "$BOTH"   # order-insensitive
expect_fail gog_assert_slice_set $'ios-arm64' "$BOTH"                        # missing
expect_fail gog_assert_slice_set $'ios-arm64\nios-arm64-simulator\nmacos-arm64' "$BOTH"  # extra
expect_fail gog_assert_slice_set $'ios-arm64_x86_64-simulator\nios-arm64' "$BOTH"

echo "── version square ──"
expect_pass gog_assert_version "0.2.1" "0.2.1" "Info.plist"
expect_fail gog_assert_version "0.2.1.0" "0.2.1" "Info.plist"   # ordinal, not semver
expect_fail gog_assert_version "" "0.2.1" "Info.plist"
expect_fail gog_assert_version "0.2.2" "0.2.1" "Info.plist"
expect_pass gog_assert_version_in_binary $'junk\n0.2.1\nmore junk' "0.2.1"
expect_fail gog_assert_version_in_binary $'junk\n0.2.10\nmore' "0.2.1"        # substring is not a match
expect_fail gog_assert_version_in_binary $'nothing useful' "0.2.1"

echo "── version format ──"
expect_pass gog_assert_version_format "0.2.1"
expect_pass gog_assert_version_format "1.0.0-rc.1"
expect_fail gog_assert_version_format "0.2"
expect_fail gog_assert_version_format "v0.2.1"
expect_fail gog_assert_version_format "0.0.0-unstamped"

echo
echo "selftest: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
