#!/bin/bash
# Block until Codex signals completion or approval via hook, or timeout.
# Creates a unique nonce per wait cycle to avoid tmux wait-for parity issues.
#
# Usage: codex-wait-event.sh <pane_id> [timeout_seconds] [event_type]
#   pane_id:       tmux pane ID (e.g., %5)
#   timeout:       max seconds to wait (default: 300)
#   event_type:    "stop" (default), "approval", or "any"
#
# Exit codes:
#   0   = Stop fired (Codex finished turn)
#   2   = PermissionRequest fired (Codex waiting for approval) [only in "any"/"approval" mode]
#   124 = Timeout (no hook fired; use fallback)

set -euo pipefail

PANE_ID="${1:?pane_id required (e.g., %5)}"
TIMEOUT="${2:-300}"
EVENT_TYPE="${3:-stop}"

# Validate timeout is a positive number
if ! [[ "$TIMEOUT" =~ ^[0-9]+\.?[0-9]*$ ]] || [ "$(echo "$TIMEOUT <= 0" | bc -l 2>/dev/null || echo 1)" = "1" ] && ! [[ "$TIMEOUT" =~ ^[1-9] ]]; then
    # Simple fallback: just check it's digits with optional decimal
    if ! [[ "$TIMEOUT" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        echo "Error: timeout must be a positive number, got: $TIMEOUT" >&2
        exit 1
    fi
fi

# Create unique nonce for this wait cycle
NONCE="$(head -c8 /dev/urandom | xxd -p)"

# Write nonce to state directory so the hook script can find it
# Create parent dir with restrictive permissions first, then pane-specific subdir
STATE_ROOT="${TMPDIR:-/tmp}/codex-event-state"
mkdir -p -m 700 "$STATE_ROOT" 2>/dev/null || true
STATE_DIR="$STATE_ROOT/${PANE_ID#%}"
mkdir -p -m 700 "$STATE_DIR"

# Atomic nonce write: write to temp file then rename
NONCE_TMP=$(mktemp "$STATE_DIR/nonce.XXXXXX")
echo "$NONCE" > "$NONCE_TMP"
mv "$NONCE_TMP" "$STATE_DIR/nonce"

# Channel names
STOP_CHANNEL="codex-stop-${NONCE}"
APPROVAL_CHANNEL="codex-approval-${NONCE}"

# PIDs for cleanup
STOP_WAIT_PID=""
APPROVAL_WAIT_PID=""
WATCHDOG_PID=""
RESULT_FILE=$(mktemp "$STATE_DIR/result.XXXXXX")

cleanup() {
    [ -n "$STOP_WAIT_PID" ] && kill "$STOP_WAIT_PID" 2>/dev/null || true
    [ -n "$APPROVAL_WAIT_PID" ] && kill "$APPROVAL_WAIT_PID" 2>/dev/null || true
    [ -n "$WATCHDOG_PID" ] && kill "$WATCHDOG_PID" 2>/dev/null || true
    wait 2>/dev/null || true
    # Only remove nonce if it still belongs to this waiter (another waiter may have replaced it)
    if [ -f "$STATE_DIR/nonce" ] && [ "$(cat "$STATE_DIR/nonce" 2>/dev/null)" = "$NONCE" ]; then
        rm -f "$STATE_DIR/nonce"
    fi
    rm -f "$RESULT_FILE"
}
trap cleanup EXIT INT TERM

case "$EVENT_TYPE" in
  stop)
    # Wait for stop channel only
    tmux wait-for "$STOP_CHANNEL" &
    STOP_WAIT_PID=$!

    ( sleep "$TIMEOUT" && kill "$STOP_WAIT_PID" 2>/dev/null ) &
    WATCHDOG_PID=$!

    if wait "$STOP_WAIT_PID" 2>/dev/null; then
        exit 0
    else
        exit 124
    fi
    ;;

  approval)
    # Wait for approval channel only
    tmux wait-for "$APPROVAL_CHANNEL" &
    APPROVAL_WAIT_PID=$!

    ( sleep "$TIMEOUT" && kill "$APPROVAL_WAIT_PID" 2>/dev/null ) &
    WATCHDOG_PID=$!

    if wait "$APPROVAL_WAIT_PID" 2>/dev/null; then
        exit 2
    else
        exit 124
    fi
    ;;

  any)
    # Wait for BOTH channels; first to fire wins
    (tmux wait-for "$STOP_CHANNEL" && echo "stop" > "$RESULT_FILE") &
    STOP_WAIT_PID=$!

    (tmux wait-for "$APPROVAL_CHANNEL" && echo "approval" > "$RESULT_FILE") &
    APPROVAL_WAIT_PID=$!

    # Watchdog: kill both after timeout
    ( sleep "$TIMEOUT" && kill "$STOP_WAIT_PID" "$APPROVAL_WAIT_PID" 2>/dev/null ) &
    WATCHDOG_PID=$!

    # Wait for either to finish
    while true; do
        if [ -s "$RESULT_FILE" ]; then
            RESULT=$(cat "$RESULT_FILE")
            if [ "$RESULT" = "stop" ]; then
                exit 0
            elif [ "$RESULT" = "approval" ]; then
                exit 2
            fi
        fi
        # Check if both waiters are dead (timeout killed them)
        kill -0 "$STOP_WAIT_PID" 2>/dev/null || kill -0 "$APPROVAL_WAIT_PID" 2>/dev/null || exit 124
        sleep 0.2
    done
    ;;

  *)
    echo "Unknown event_type: $EVENT_TYPE (use stop, approval, or any)" >&2
    exit 1
    ;;
esac
