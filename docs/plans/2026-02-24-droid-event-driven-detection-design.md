# Event-Driven Detection for Droid CLI Skill

## Problem

The droid-cli-interactive skill uses fixed idle-time polling (`tmux-cli wait_idle --idle-time=30s`) to detect when Droid finishes responding. This is wasteful (waits full 30s even for fast responses) and fragile (may timeout early on slow responses).

## Goal

Replace fixed polling with event-driven detection using Droid hooks + `tmux wait-for`, with graceful fallback to `wait_idle` on failure.

## Constraints

- Must support multiple concurrent Droid instances
- Must not corrupt `~/.factory/settings.json`
- Must handle Droid crashes gracefully
- Must be backwards-compatible (skill still works if hooks aren't installed)

## Research Findings

### tmux `wait-for` Semantics (Experimentally Verified, tmux 3.5a)

| Behavior | Result |
|----------|--------|
| One signal wakes... | One waiter only (not broadcast) |
| Signal before wait | Latched (immediate return) |
| Repeated signals | Parity-like toggle (odd=wake, even=block) |
| Counting semaphore | NO - not safe for repeated events on same channel |

**Critical implication**: Cannot reuse the same channel name for repeated events. Each wait cycle needs a unique channel or a nonce handshake to avoid parity issues.

### Droid Hook Events

| Event | Fires When |
|-------|-----------|
| `Stop` | Response generation complete |
| `SubagentStop` | Subagent finishes |
| `Notification` | Needs user interaction/permission |
| `PreToolUse` / `PostToolUse` | Before/after tool execution |
| `SessionStart` / `SessionEnd` | Session lifecycle |

Hooks receive JSON on stdin: `{"session_id", "hook_event_name", "cwd", ...}`

### Codex Review Findings (GPT-5.3-Codex, xhigh)

1. **CRITICAL**: `wait-for` parity semantics make reused channels unsafe
2. **HIGH**: PID ancestry discovery can break during shutdown/reparenting
3. **HIGH**: Per-session inject/remove of settings.json is crash-unsafe
4. **Key simplification**: Install hooks once permanently, make them no-op when not in managed tmux windows

## Architecture

### Overview

```
┌─────────────┐     tmux send      ┌──────────┐
│ Claude Code  │ ──────────────────> │  Droid   │
│  (skill)    │                     │  (TUI)   │
└──────┬──────┘                     └────┬─────┘
       │                                 │
       │  tmux wait-for                  │ hook fires (Stop event)
       │  "droid-NONCE"                  │
       │                                 ▼
       │                          ┌──────────────┐
       │  <── tmux wait-for -S ── │ hook-signal  │
       │      "droid-NONCE"       │   .sh        │
       │                          └──────────────┘
       ▼
  capture output
```

### Design Principles

1. **One-time hook installation**: Hooks are installed once and left permanently. No per-session inject/remove cycle. The hook script is a no-op when not in a managed tmux window.
2. **Nonce-per-wait**: Each wait cycle uses a unique channel name (`droid-<nonce>`) to avoid `wait-for` parity issues. The nonce is passed to the hook via a marker file.
3. **Graceful fallback**: If hook signaling fails, the skill falls back to `wait_idle` polling.
4. **Process tree discovery**: The hook script walks PID ancestry to find which tmux pane/window it belongs to, then reads the nonce from a marker file in that window's state directory.

## Scripts

### 1. `scripts/droid-hook-signal.sh`

Called by Droid on hook events. Discovers its tmux window via PID ancestry, reads the current nonce, and signals the correct `tmux wait-for` channel.

```bash
#!/bin/bash
# Called by Droid hooks. Reads JSON from stdin, discovers tmux window,
# signals the unique wait-for channel.

set -euo pipefail

# Parse hook event from stdin JSON
EVENT=$(cat | python3 -c "import sys,json; print(json.load(sys.stdin).get('hook_event_name',''))" 2>/dev/null) || exit 0

# Only handle events we care about
case "$EVENT" in
  Stop|SubagentStop|Notification) ;;
  *) exit 0 ;;
esac

# Walk PID ancestry to find tmux pane
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

# Read nonce from state directory
STATE_DIR="/tmp/droid-event-state/${PANE_ID#%}"
NONCE_FILE="$STATE_DIR/nonce"
[ -f "$NONCE_FILE" ] || exit 0
NONCE=$(cat "$NONCE_FILE")
[ -n "$NONCE" ] || exit 0

# Signal the channel
case "$EVENT" in
  Stop|SubagentStop)
    tmux wait-for -S "droid-${NONCE}" 2>/dev/null ;;
  Notification)
    tmux wait-for -S "droid-notify-${NONCE}" 2>/dev/null ;;
esac
```

**Key design choices**:
- Uses `pane_id` (e.g., `%5`) not `window_name` for identification (more stable per Codex review)
- Nonce file per pane ensures each wait cycle gets its own channel
- Silent failure (`exit 0`) on any error - hook must never break Droid
- `set -euo pipefail` for script safety

### 2. `scripts/droid-wait-event.sh`

Called by the skill to block until Droid responds. Creates a unique nonce, writes it to the state directory, then waits on the corresponding `tmux wait-for` channel with a timeout.

```bash
#!/bin/bash
# Block until Droid signals completion or timeout.
# Usage: droid-wait-event.sh <pane_id> [timeout_seconds] [event_type]
# event_type: "stop" (default) or "notify"

set -euo pipefail

PANE_ID="${1:?pane_id required}"
TIMEOUT="${2:-300}"
EVENT_TYPE="${3:-stop}"

# Create unique nonce for this wait cycle
NONCE="$(head -c8 /dev/urandom | xxd -p)"

# Write nonce to state directory
STATE_DIR="/tmp/droid-event-state/${PANE_ID#%}"
mkdir -p "$STATE_DIR"
echo "$NONCE" > "$STATE_DIR/nonce"

# Determine channel name
if [ "$EVENT_TYPE" = "notify" ]; then
    CHANNEL="droid-notify-${NONCE}"
else
    CHANNEL="droid-${NONCE}"
fi

# Wait with timeout
cleanup() {
    kill "$WAIT_PID" 2>/dev/null || true
    kill "$WATCHDOG_PID" 2>/dev/null || true
    wait "$WAIT_PID" 2>/dev/null || true
    wait "$WATCHDOG_PID" 2>/dev/null || true
    rm -f "$STATE_DIR/nonce"
}
trap cleanup EXIT INT TERM

tmux wait-for "$CHANNEL" &
WAIT_PID=$!

( sleep "$TIMEOUT" && kill "$WAIT_PID" 2>/dev/null ) &
WATCHDOG_PID=$!

wait "$WAIT_PID" 2>/dev/null
EXIT_CODE=$?

exit $EXIT_CODE
```

**Key design choices**:
- Fresh nonce per call eliminates `wait-for` parity issues entirely
- `trap cleanup EXIT INT TERM` prevents zombie/orphan processes (Codex concern #5)
- Cleans up nonce file on exit
- Returns 0 on signal (success), non-zero on timeout (fallback to `wait_idle`)

### 3. `scripts/droid-install-hooks.sh`

One-time idempotent installation of hooks into `~/.factory/settings.json`. Run once at skill setup, not per session.

```bash
#!/bin/bash
# Idempotently install Droid hooks for event-driven detection.
# Safe to run multiple times - checks if hooks already present.

set -euo pipefail

SETTINGS="$HOME/.factory/settings.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/droid-hook-signal.sh"

# Ensure settings file exists
if [ ! -f "$SETTINGS" ]; then
    mkdir -p "$(dirname "$SETTINGS")"
    echo '{}' > "$SETTINGS"
fi

# Check if hooks already installed (idempotent)
if python3 -c "
import json, sys
with open('$SETTINGS') as f:
    cfg = json.load(f)
hooks = cfg.get('hooks', {})
if 'Stop' in hooks and '$HOOK_SCRIPT' in str(hooks['Stop']):
    sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
    echo "Hooks already installed"
    exit 0
fi

# Backup current settings (once, don't overwrite existing backup)
BACKUP="$SETTINGS.pre-hooks-backup"
if [ ! -f "$BACKUP" ]; then
    cp "$SETTINGS" "$BACKUP"
fi

# Merge hooks using atomic temp+rename
python3 -c "
import json, tempfile, os

settings_path = '$SETTINGS'
hook_script = '$HOOK_SCRIPT'

with open(settings_path) as f:
    cfg = json.load(f)

hook_entry = {'command': hook_script}
hooks = cfg.setdefault('hooks', {})
for event in ['Stop', 'SubagentStop', 'Notification']:
    hooks[event] = [hook_entry]

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(settings_path))
with os.fdopen(fd, 'w') as f:
    json.dump(cfg, f, indent=2)
os.rename(tmp, settings_path)
"

echo "Hooks installed successfully"
echo "Backup saved to: $BACKUP"
```

**Key design choices**:
- **Idempotent**: Checks if hooks already present before modifying
- **Atomic write**: Uses `tempfile + os.rename` to prevent corruption (Codex concern #3)
- **One-time backup**: Saves original settings before first modification
- **No per-session inject/remove**: Eliminates entire reference-counting complexity (Codex's key simplification)

## Skill SKILL.md Changes

The skill's send+capture pattern changes from:

```bash
# OLD: Fixed idle-time polling
tmux-cli send "<PROMPT>" --pane=$DROID_PANE && \
tmux-cli wait_idle --pane=$DROID_PANE --idle-time=30.0 && \
tmux-cli capture --pane=$DROID_PANE
```

To:

```bash
# NEW: Event-driven with fallback
PANE_ID=$(tmux display-message -t $DROID_PANE -p '#{pane_id}')
tmux-cli send "<PROMPT>" --pane=$DROID_PANE && \
(SCRIPT_DIR/droid-wait-event.sh "$PANE_ID" 300 || \
 tmux-cli wait_idle --pane=$DROID_PANE --idle-time=30.0) && \
tmux-cli capture --pane=$DROID_PANE
```

The setup section adds a one-time hook installation check:

```bash
# 0. Ensure hooks are installed (one-time, idempotent)
SCRIPT_DIR="path/to/droid-cli-interactive/scripts"
"$SCRIPT_DIR/droid-install-hooks.sh"
```

## Concurrency Safety Analysis

| Concern | Solution |
|---------|----------|
| Multiple instances signaling same channel | Each wait creates unique nonce -> unique channel |
| `wait-for` parity/toggle | Fresh nonce per wait = fresh channel, no reuse |
| Settings.json race conditions | One-time install, no per-session modification |
| Crash mid-session | Hook stays installed (harmless), nonce file cleaned up by trap or next instance |
| PID ancestry breaks | `wait-for` times out -> falls back to `wait_idle` |
| Zombie/orphan processes | `trap cleanup EXIT INT TERM` in wait script |
| Stale state files | `/tmp` cleared on reboot; nonce file removed on script exit |

## Fallback Behavior

If event-driven detection fails for any reason (hook not installed, PID ancestry fails, tmux server issue), the `droid-wait-event.sh` script exits non-zero after timeout, and the `||` fallback triggers `wait_idle` with the original fixed idle-time. This ensures the skill always works, just slower in degraded mode.

## Implementation Plan

1. Create `scripts/` directory in droid-cli-interactive
2. Write `droid-hook-signal.sh` (hook dispatcher)
3. Write `droid-wait-event.sh` (blocking waiter with timeout)
4. Write `droid-install-hooks.sh` (one-time idempotent installer)
5. Update `SKILL.md` with new send+capture pattern and setup step
6. Test with single instance
7. Test with concurrent instances
8. Commit and push
