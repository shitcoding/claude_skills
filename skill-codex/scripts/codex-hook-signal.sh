#!/bin/bash
# Called by Codex hooks (Stop, PermissionRequest).
# Discovers which tmux pane this process belongs to via PID ancestry,
# reads the current wait nonce, and signals the corresponding tmux wait-for channel.
#
# Signals two distinct channels per nonce:
#   codex-stop-<NONCE>     for Stop events
#   codex-approval-<NONCE> for PermissionRequest events
#
# Designed to be safe: silent exit on any error, never breaks Codex.
# IMPORTANT: Must produce NO stdout for Stop events (Codex expects JSON or empty).

set -uo pipefail
# NOTE: set -e intentionally omitted -- this script must never exit non-zero
# because Codex treats non-zero hook exits as errors. Every command that can
# fail has an explicit || exit 0 guard.

# Parse hook event from stdin JSON
EVENT=$(cat | python3 -c "import sys,json; print(json.load(sys.stdin).get('hook_event_name',''))" 2>/dev/null) || exit 0

# Only handle events we care about
case "$EVENT" in
  Stop|PermissionRequest) ;;
  *) exit 0 ;;
esac

# Walk PID ancestry to find the tmux pane this hook belongs to.
# Codex runs hooks via $SHELL -lc <command>, so the chain is:
#   codex-hook-signal.sh -> sh/bash -> codex -> zsh -> tmux (pane_pid)
find_tmux_pane() {
    local pid=$$
    while [ "$pid" -gt 1 ] 2>/dev/null; do
        local match
        match=$(tmux list-panes -a -F '#{pane_pid} #{pane_id}' 2>/dev/null \
            | awk -v p="$pid" '$1==p {print $2}') || true
        if [ -n "$match" ]; then
            echo "$match"
            return 0
        fi
        local ppid
        ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') || return 1
        # Validate numeric PID to avoid test errors
        [[ "$ppid" =~ ^[0-9]+$ ]] || return 1
        pid=$ppid
    done
    return 1
}

PANE_ID=$(find_tmux_pane) || exit 0

# Read nonce from state directory (pane_id without % prefix)
STATE_DIR="${TMPDIR:-/tmp}/codex-event-state/${PANE_ID#%}"
NONCE_FILE="$STATE_DIR/nonce"
[ -f "$NONCE_FILE" ] || exit 0
NONCE=$(cat "$NONCE_FILE" 2>/dev/null) || exit 0

# Validate nonce: must be hex, 16 chars
[[ "$NONCE" =~ ^[0-9a-f]{16}$ ]] || exit 0

# Signal the appropriate channel (|| true to never exit non-zero)
case "$EVENT" in
  Stop)
    tmux wait-for -S "codex-stop-${NONCE}" 2>/dev/null || true ;;
  PermissionRequest)
    tmux wait-for -S "codex-approval-${NONCE}" 2>/dev/null || true ;;
esac

exit 0
