#!/usr/bin/env bash
#
# Boots a throwaway Codeman, drives the app through onboarding → launch → terminal on a phone and
# a tablet simulator, and extracts the screenshots.
#
# This is the check that the terminal actually RENDERS. A green build and a green test suite still
# cannot tell you whether Metal drew anything; only pixels can.
#
# Usage:  Scripts/capture-screenshots.sh [output-dir]

set -euo pipefail

OUT_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Screenshots}"
PORT=3188
INSTANCE="native-shots"
PASSWORD="native-screenshots-$(date +%s)"

PHONE="${SCREENSHOT_PHONE:-iPhone 17 Pro}"
TABLET="${SCREENSHOT_TABLET:-iPad Pro 13-inch (M5)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${PROJECT_DIR}/../.." && pwd)"

if [ ! -x "${REPO_ROOT}/node_modules/.bin/tsx" ]; then
    echo "ERROR: dependencies are not installed. Run 'npm install' in ${REPO_ROOT} first." >&2
    exit 1
fi

if lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "ERROR: port ${PORT} is already in use:" >&2
    lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN >&2
    exit 1
fi

# Point at a Codeman that is already running when one is given: booting a throwaway server per
# capture is ~30s of the runtime and buys nothing when a real one is available.
#   CODEMAN_TEST_URL=http://127.0.0.1:3000 Scripts/capture-screenshots.sh
RESULT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codeman-native-xcresult.XXXXXX")"
DATA_DIR=""
SERVER_PID=""

cleanup() {
    if [ -n "${SERVER_PID}" ] && kill -0 "${SERVER_PID}" 2>/dev/null; then
        kill -TERM -"${SERVER_PID}" 2>/dev/null || kill -TERM "${SERVER_PID}" 2>/dev/null || true
        wait "${SERVER_PID}" 2>/dev/null || true
        kill -KILL -"${SERVER_PID}" 2>/dev/null || true
        tmux -L "codeman-${INSTANCE}" kill-server 2>/dev/null || true
    fi
    if [ "${KEEP_RESULTS:-0}" = "1" ]; then
        echo "==> Keeping diagnostics in ${RESULT_DIR}"
    else
        rm -rf "${RESULT_DIR}"
    fi
    [ -n "${DATA_DIR}" ] && rm -rf "${DATA_DIR}"
}
trap cleanup EXIT

if [ -n "${CODEMAN_TEST_URL:-}" ]; then
    URL="${CODEMAN_TEST_URL}"
    PASSWORD="${CODEMAN_TEST_PASSWORD:-}"
    echo "==> Using the Codeman already running at ${URL}"
    curl -fsSk -u "admin:${PASSWORD}" "${URL}/api/status" >/dev/null 2>&1 \
        || { echo "ERROR: nothing answering at ${URL}." >&2; exit 1; }
else
    URL="http://127.0.0.1:${PORT}"
    DATA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codeman-native-shots.XXXXXX")"
    LOG_FILE="${DATA_DIR}/server.log"

    if lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
        echo "ERROR: port ${PORT} is already in use:" >&2
        lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN >&2
        exit 1
    fi

    echo "==> Starting Codeman on :${PORT}"
    set -m
    (
        cd "${REPO_ROOT}"
        CODEMAN_INSTANCE="${INSTANCE}" \
        CODEMAN_DATA_DIR="${DATA_DIR}" \
        CODEMAN_PASSWORD="${PASSWORD}" \
        CODEMAN_USERNAME="admin" \
        ./node_modules/.bin/tsx src/index.ts web --port "${PORT}" >"${LOG_FILE}" 2>&1
    ) &
    SERVER_PID=$!
    set +m

    for _ in $(seq 1 60); do
        curl -fsS -u "admin:${PASSWORD}" "${URL}/api/status" >/dev/null 2>&1 && break
        if ! kill -0 "${SERVER_PID}" 2>/dev/null; then
            echo "ERROR: the server exited during startup:" >&2; cat "${LOG_FILE}" >&2; exit 1
        fi
        sleep 1
    done
    curl -fsS -u "admin:${PASSWORD}" "${URL}/api/status" >/dev/null 2>&1 \
        || { echo "ERROR: server never answered." >&2; cat "${LOG_FILE}" >&2; exit 1; }
    echo "==> Server is up"
fi

mkdir -p "${OUT_DIR}"
cd "${PROJECT_DIR}"

capture_for() {
    local device="$1" slug="$2"
    local result="${RESULT_DIR}/${slug}.xcresult"

    # Turn off AutoFill passwords before the run: its "Save Password?" sheet is presented inside
    # the app's own hierarchy and swallows the next tap, which makes every credential-entering
    # capture a coin flip.
    "${SCRIPT_DIR}/prepare-simulator.sh" "${device}"

    echo "==> Capturing on ${device}"
    rm -rf "${result}"
    xcodebuild \
        -project CodemanNative.xcodeproj \
        -scheme CodemanNative \
        -destination "platform=iOS Simulator,name=${device}" \
        -only-testing:CodemanNativeUITests/ScreenshotUITests \
        -resultBundlePath "${result}" \
        -parallel-testing-enabled NO \
        test \
        CODEMAN_TEST_URL="${URL}" \
        CODEMAN_TEST_USERNAME="admin" \
        CODEMAN_TEST_PASSWORD="${PASSWORD}" \
        >"${RESULT_DIR}/${slug}.log" 2>&1 || {
            echo "ERROR: the capture run failed on ${device}. Tail of the log:" >&2
            grep -E "error:|XCTAssert|failed \\(" "${RESULT_DIR}/${slug}.log" | head -20 >&2
            echo "    full log: ${RESULT_DIR}/${slug}.log" >&2
            KEEP_RESULTS=1
            return 1
        }

    local dest="${OUT_DIR}/${slug}"
    rm -rf "${dest}"
    mkdir -p "${dest}"
    # `xcresulttool export attachments` writes every attachment plus a manifest naming them.
    xcrun xcresulttool export attachments \
        --path "${result}" \
        --output-path "${dest}" >/dev/null

    # The manifest maps generated filenames back to the names the test gave them.
    python3 - "${dest}" <<'PY'
import json, pathlib, shutil, sys

destination = pathlib.Path(sys.argv[1])
manifest_path = destination / "manifest.json"
if not manifest_path.exists():
    print(f"    (no manifest in {destination})")
    raise SystemExit(0)

manifest = json.loads(manifest_path.read_text())
renamed = 0
for entry in manifest:
    for attachment in entry.get("attachments", []):
        exported = attachment.get("exportedFileName")
        suggested = attachment.get("suggestedHumanReadableName") or ""
        if not exported or not suggested:
            continue
        source = destination / exported
        if not source.exists():
            continue
        stem = pathlib.Path(suggested).stem or pathlib.Path(exported).stem
        shutil.move(str(source), str(destination / f"{stem}.png"))
        renamed += 1
print(f"    exported {renamed} screenshot(s)")
PY

    echo "==> ${device}: $(ls -1 "${dest}"/*.png 2>/dev/null | wc -l | tr -d ' ') screenshots in ${dest}"
}

capture_for "${PHONE}" "phone"
capture_for "${TABLET}" "tablet"

echo "==> Done. Screenshots in ${OUT_DIR}"
ls -1 "${OUT_DIR}"/*/*.png 2>/dev/null || true
