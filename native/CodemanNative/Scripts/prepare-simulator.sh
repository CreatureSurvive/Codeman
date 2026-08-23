#!/usr/bin/env bash
#
# Prepares a simulator for unattended UI runs by turning off AutoFill passwords.
#
# Why: typing into a SecureField next to a username field trips iOS's login-form heuristic, and
# the resulting "Save Password?" sheet is presented as a remote view controller inside the app's
# own hierarchy. `addUIInterruptionMonitor` does not fire for it reliably and it swallows the next
# tap, so every credential-entering UI test becomes a coin flip.
#
# Disabling the feature on the simulator is the honest fix: the prompt is real iOS behaviour that
# a user should keep, so the app does not suppress it — the *test device* opts out instead.
#
# The simulator must be shut down while its preferences are written, or CoreSimulator overwrites
# them from its in-memory copy on the next quit.
#
# Usage:  Scripts/prepare-simulator.sh "iPhone 17 Pro"

set -euo pipefail

TARGET_DEVICE="${1:?usage: prepare-simulator.sh <device name>}"

echo "==> Finding UDID for ${TARGET_DEVICE}"
SIM_UDID="$(
    xcrun simctl list devices available --json \
        | python3 -c '
import json, sys
target = sys.argv[1]
data = json.load(sys.stdin)["devices"]
for runtime, devices in sorted(data.items(), reverse=True):
    for device in devices:
        if device.get("name") == target and device.get("isAvailable"):
            print(device["udid"])
            raise SystemExit(0)
raise SystemExit(1)
' "${TARGET_DEVICE}"
)" || {
    echo "ERROR: no available simulator named '${TARGET_DEVICE}'." >&2
    exit 1
}

echo "==> ${TARGET_DEVICE} is ${SIM_UDID}"

PREFS="${HOME}/Library/Developer/CoreSimulator/Devices/${SIM_UDID}/data/Library/Preferences/.GlobalPreferences.plist"

echo "==> Shutting the simulator down so preferences can be written"
xcrun simctl shutdown "${SIM_UDID}" 2>/dev/null || true
# `simctl shutdown` returns before the device fully quits; writing too early is silently undone.
for _ in $(seq 1 20); do
    state="$(xcrun simctl list devices | grep "${SIM_UDID}" | sed -n 's/.*(\(Booted\|Shutdown\|Shutting Down\)).*/\1/p' | head -1)"
    [ "${state}" = "Shutdown" ] && break
    sleep 1
done

echo "==> Disabling AutoFill passwords"
mkdir -p "$(dirname "${PREFS}")"
defaults write "${PREFS}" AutoFillPasswordsEnabled -bool false
defaults write "${PREFS}" com.apple.Safari.AutoFill.Passwords -bool false

echo "==> Booting ${TARGET_DEVICE}"
xcrun simctl boot "${SIM_UDID}" 2>/dev/null || true
xcrun simctl bootstatus "${SIM_UDID}" -b >/dev/null 2>&1 || true

echo "==> ${TARGET_DEVICE} ready"
