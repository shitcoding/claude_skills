#!/bin/bash
# Block until Droid signals completion via hook, or timeout.
# Creates a unique nonce per wait cycle to avoid tmux wait-for parity issues.
#
# Usage: droid-wait-event.sh <pane_id> [timeout_seconds] [event_type]
#   pane_id:       tmux pane ID (e.g., %5)
#   timeout:       max seconds to wait (default: 300)
#   event_type:    "stop" (default) or "notify"
#
# Exit codes: 0 = signaled (Droid finished), non-zero = timeout (use fallback)

set -euo pipefail

PANE_ID="${1:?pane_id required (e.g., %5)}"
TIMEOUT="${2:-300}"
EVENT_TYPE="${3:-stop}"

# Create unique nonce for this wait cycle
NONCE="$(head -c8 /dev/urandom | xxd -p)"

# Write nonce to state directory so the hook script can find it
STATE_DIR="/tmp/droid-event-state/${PANE_ID#%}"
mkdir -p "$STATE_DIR"
echo "$NONCE" > "$STATE_DIR/nonce"

# Determine channel name based on event type
if [ "$EVENT_TYPE" = "notify" ]; then
    CHANNEL="droid-notify-${NONCE}"
else
    CHANNEL="droid-${NONCE}"
fi

# Ensure cleanup of child processes and state on exit
WAIT_PID=""
WATCHDOG_PID=""

cleanup() {
    [ -n "$WAIT_PID" ] && kill "$WAIT_PID" 2>/dev/null || true
    [ -n "$WATCHDOG_PID" ] && kill "$WATCHDOG_PID" 2>/dev/null || true
    [ -n "$WAIT_PID" ] && wait "$WAIT_PID" 2>/dev/null || true
    [ -n "$WATCHDOG_PID" ] && wait "$WATCHDOG_PID" 2>/dev/null || true
    rm -f "$STATE_DIR/nonce"
}
trap cleanup EXIT INT TERM

# Start tmux wait-for in background
tmux wait-for "$CHANNEL" &
WAIT_PID=$!

# Start watchdog timer that kills the wait after timeout
( sleep "$TIMEOUT" && kill "$WAIT_PID" 2>/dev/null ) &
WATCHDOG_PID=$!

# Block until either the signal arrives or timeout kills us
wait "$WAIT_PID" 2>/dev/null
EXIT_CODE=$?

exit $EXIT_CODE
