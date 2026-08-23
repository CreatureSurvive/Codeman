#!/usr/bin/env bash
#
# Runs one server-backed UI test in seconds instead of minutes.
#
# Three things make the slow path slow, and this removes all three:
#   1. booting a throwaway Codeman per run  → point at a server that is already up
#   2. typing the address and password through the on-screen keyboard on every launch
#      → `-server-url` / `-server-password` connect the app directly (UI-testing only)
#   3. a full rebuild per run → `build-for-testing` once, then `test-without-building`
#
# Usage:
#   Scripts/fast-ui-test.sh CodemanNativeUITests/ScrollbackUITests [device]
#
# Environment:
#   CODEMAN_TEST_URL       server to drive (default http://127.0.0.1:3000)
#   CODEMAN_TEST_PASSWORD  its password (default: read from ~/.codeman/.env)
#   REBUILD=1              force the build-for-testing step

set -euo pipefail

TESTS="${1:?usage: fast-ui-test.sh <Bundle/Suite[/testMethod]> [device]}"
DEVICE="${2:-iPhone 17 Pro}"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_DIR}"

URL="${CODEMAN_TEST_URL:-http://127.0.0.1:3000}"
if [ -z "${CODEMAN_TEST_PASSWORD:-}" ] && [ -f "${HOME}/.codeman/.env" ]; then
    CODEMAN_TEST_PASSWORD="$(sed -n 's/^CODEMAN_PASSWORD=//p' "${HOME}/.codeman/.env" | head -1 | tr -d '"'"'"'')"
fi
PASSWORD="${CODEMAN_TEST_PASSWORD:-}"

echo "==> Checking ${URL}"
if ! curl -fsSk -u "admin:${PASSWORD}" "${URL}/api/status" >/dev/null 2>&1; then
    echo "ERROR: no Codeman answering at ${URL}." >&2
    echo "       Set CODEMAN_TEST_URL / CODEMAN_TEST_PASSWORD, or start one." >&2
    exit 1
fi

DERIVED="$(xcodebuild -project CodemanNative.xcodeproj -scheme CodemanNative -showBuildSettings 2>/dev/null \
    | sed -n 's/ *BUILD_DIR = //p' | head -1)"
XCTESTRUN_GLOB="${DERIVED%/Build/Products}/Build/Products/*.xctestrun"

if [ "${REBUILD:-0}" = "1" ] || ! compgen -G "${XCTESTRUN_GLOB}" >/dev/null; then
    echo "==> build-for-testing"
    xcodebuild -project CodemanNative.xcodeproj -scheme CodemanNative \
        -destination "platform=iOS Simulator,name=${DEVICE}" \
        build-for-testing >/dev/null
fi

echo "==> ${TESTS} against ${URL}"
xcodebuild -project CodemanNative.xcodeproj -scheme CodemanNative \
    -destination "platform=iOS Simulator,name=${DEVICE}" \
    -only-testing:"${TESTS}" \
    -parallel-testing-enabled NO \
    test-without-building \
    CODEMAN_TEST_URL="${URL}" \
    CODEMAN_TEST_USERNAME="admin" \
    CODEMAN_TEST_PASSWORD="${PASSWORD}"
