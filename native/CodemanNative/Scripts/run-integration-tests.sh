#!/usr/bin/env bash
#
# Boots a throwaway Codeman on port 3187 and runs the native integration suite against it.
#
# Isolation matters here: the tmux socket and data dir are PROCESS-WIDE in Codeman, and a second
# instance on the default socket discovers and attaches PTYs to the first instance's live
# sessions. CODEMAN_INSTANCE scopes the data dir and the socket together, so this can never touch
# a running production Codeman or the user's real w1/w2/w3 sessions.
#
# Usage:  Scripts/run-integration-tests.sh [simulator-name]
#
# ONLY_TESTING overrides which bundle runs, for the server-backed UI suites:
#   ONLY_TESTING=-only-testing:CodemanNativeUITests/ScrollbackUITests Scripts/run-integration-tests.sh

set -euo pipefail

SIMULATOR="${1:-iPhone 17}"
PORT=3187
INSTANCE="native-itest"
PASSWORD="native-integration-$(date +%s)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${PROJECT_DIR}/../.." && pwd)"

if [ ! -f "${REPO_ROOT}/package.json" ]; then
    echo "ERROR: could not find the Codeman checkout at ${REPO_ROOT}" >&2
    exit 1
fi

if [ ! -x "${REPO_ROOT}/node_modules/.bin/tsx" ]; then
    echo "ERROR: dependencies are not installed. Run 'npm install' in ${REPO_ROOT} first." >&2
    exit 1
fi

if lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "ERROR: port ${PORT} is already in use — a previous run may still be alive:" >&2
    lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN >&2
    exit 1
fi

DATA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codeman-native-itest.XXXXXX")"
LOG_FILE="${DATA_DIR}/server.log"
SERVER_PID=""

cleanup() {
    if [ -n "${SERVER_PID}" ] && kill -0 "${SERVER_PID}" 2>/dev/null; then
        echo "==> Stopping test server (process group ${SERVER_PID})"
        # Kill the GROUP, not just the wrapper subshell: `kill $!` leaves the node child holding
        # the port, and the next run then fails to bind with an empty log — which reads as "the
        # server crashed" rather than "the last one is still alive".
        kill -TERM -"${SERVER_PID}" 2>/dev/null || kill -TERM "${SERVER_PID}" 2>/dev/null || true
        wait "${SERVER_PID}" 2>/dev/null || true
        for _ in $(seq 1 10); do
            lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN >/dev/null 2>&1 || break
            sleep 1
        done
        kill -KILL -"${SERVER_PID}" 2>/dev/null || true
    fi
    # Kill only THIS instance's tmux server, never the default socket.
    tmux -L "codeman-${INSTANCE}" kill-server 2>/dev/null || true
    rm -rf "${DATA_DIR}"
}
trap cleanup EXIT

echo "==> Starting Codeman on :${PORT} (instance ${INSTANCE}, data ${DATA_DIR})"
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

echo "==> Waiting for /api/status"
for _ in $(seq 1 60); do
    if curl -fsS -u "admin:${PASSWORD}" "http://127.0.0.1:${PORT}/api/status" >/dev/null 2>&1; then
        echo "==> Server is up"
        break
    fi
    if ! kill -0 "${SERVER_PID}" 2>/dev/null; then
        echo "ERROR: the server exited during startup. Log:" >&2
        cat "${LOG_FILE}" >&2
        exit 1
    fi
    sleep 1
done

if ! curl -fsS -u "admin:${PASSWORD}" "http://127.0.0.1:${PORT}/api/status" >/dev/null 2>&1; then
    echo "ERROR: the server never answered /api/status. Log:" >&2
    cat "${LOG_FILE}" >&2
    exit 1
fi

echo "==> Running the integration suite against 127.0.0.1:${PORT}"
cd "${PROJECT_DIR}"
xcodebuild \
    -project CodemanNative.xcodeproj \
    -scheme CodemanNative \
    -destination "platform=iOS Simulator,name=${SIMULATOR}" \
    ${ONLY_TESTING:--only-testing:CodemanNativeTests/IntegrationTests} \
    -parallel-testing-enabled NO \
    test \
    CODEMAN_TEST_URL="http://127.0.0.1:${PORT}" \
    CODEMAN_TEST_USERNAME="admin" \
    CODEMAN_TEST_PASSWORD="${PASSWORD}"

# These are BUILD SETTINGS. The scheme's test action declares matching environment variables whose
# values are `$(CODEMAN_TEST_URL)` etc., and Xcode expands them into the test process. Passing them
# as `TEST_RUNNER_`-prefixed settings instead only works for an XCUITest runner — a hosted
# unit-test bundle never sees those, which is exactly the trap this comment exists to prevent.
# The simulator shares the host network stack, so 127.0.0.1 reaches this server.
