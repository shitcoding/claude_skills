#!/bin/bash
# Called by Droid hooks (Stop, SubagentStop, Notification).
# Discovers which tmux pane this process belongs to via PID ancestry,
# reads the current wait nonce, and signals the corresponding tmux wait-for channel.
# Designed to be safe: silent exit on any error, never breaks Droid.

set -euo pipefail

# Parse hook event from stdin JSON
EVENT=$(cat | python3 -c "import sys,json; print(json.load(sys.stdin).get('hook_event_name',''))" 2>/dev/null) || exit 0

# Only handle events we care about
case "$EVENT" in
  Stop|SubagentStop|Notification) ;;
  *) exit 0 ;;
esac

# Walk PID ancestry to find the tmux pane this hook belongs to.
# Chain: droid-hook-signal.sh -> droid -> zsh -> tmux (pane_pid)
find_tmux_pane() {
    local pid=$$
    while [ "$pid" -gt 1 ]; do
        local match
        match=$(tmux list-panes -a -F '#{pane_pid} #{pane_id}' 2>/dev/null \
            | awk -v p="$pid" '$1==p {print $2}')
        if [ -n "$match" ]; then
            echo "$match"
            return 0
        fi
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    done
    return 1
}

PANE_ID=$(find_tmux_pane) || exit 0

# Read nonce from state directory (pane_id without % prefix)
STATE_DIR="/tmp/droid-event-state/${PANE_ID#%}"
NONCE_FILE="$STATE_DIR/nonce"
[ -f "$NONCE_FILE" ] || exit 0
NONCE=$(cat "$NONCE_FILE")
[ -n "$NONCE" ] || exit 0

# Signal the appropriate channel
case "$EVENT" in
  Stop|SubagentStop)
    tmux wait-for -S "droid-${NONCE}" 2>/dev/null ;;
  Notification)
    tmux wait-for -S "droid-notify-${NONCE}" 2>/dev/null ;;
esac
