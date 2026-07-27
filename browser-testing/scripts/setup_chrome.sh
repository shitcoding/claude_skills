#!/usr/bin/env bash
# setup_chrome.sh — Launch/stop headed Chrome with CDP for browser automation.
#
# Uses config/chrome-profile/ for persistent sessions (login state survives restart).
# Idempotent: won't start a second Chrome if one is already running on the CDP port.
#
# Usage:
#   setup_chrome.sh              # Start Chrome
#   setup_chrome.sh --stop       # Graceful stop (cookies persist, tabs do not)
#   setup_chrome.sh --login URL  # Start Chrome, open URL for manual login
#   setup_chrome.sh --status     # Check if Chrome is running
#   setup_chrome.sh URL [URL...] # Start Chrome and open URLs
#
# Environment:
#   CDP_PORT=9333          Override CDP port (default: 9333)
#   BT_CHROME_PROFILE=DIR  Override profile dir (default: <skill>/config/chrome-profile)
#   CHROME_BIN=PATH        Override browser binary (any Chromium-based browser)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
CHROME_PROFILE="${BT_CHROME_PROFILE:-$SKILL_DIR/config/chrome-profile}"
CDP_PORT="${CDP_PORT:-9333}"

# ── Helpers ──────────────────────────────────────────────────────────────

chrome_running() {
    curl -s --max-time 2 "http://localhost:$CDP_PORT/json/version" &>/dev/null
}

find_chrome_binary() {
    if [[ -n "${CHROME_BIN:-}" ]]; then
        echo "$CHROME_BIN"
        return
    fi
    local candidates=(
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        "/Applications/Chromium.app/Contents/MacOS/Chromium"
        "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"
    )
    for c in "${candidates[@]}"; do
        [[ -x "$c" ]] && { echo "$c"; return; }
    done
    for c in google-chrome google-chrome-stable chromium chromium-browser microsoft-edge microsoft-edge-stable brave-browser; do
        command -v "$c" &>/dev/null && { echo "$c"; return; }
    done
    echo ""
}

print_status() {
    if chrome_running; then
        echo "Chrome is RUNNING on CDP port $CDP_PORT"
        curl -s "http://localhost:$CDP_PORT/json/version" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(f\"  Browser: {data.get('Browser', 'unknown')}\")
print(f\"  WebSocket: {data.get('webSocketDebuggerUrl', 'unknown')}\")
" 2>/dev/null || true
        echo "  Tabs:"
        curl -s "http://localhost:$CDP_PORT/json" | python3 -c "
import json, sys
tabs = json.load(sys.stdin)
for t in tabs:
    if t.get('type') == 'page':
        print(f\"    - {t.get('title', '(no title)')[:60]}  [{t.get('url', '')[:80]}]\")
" 2>/dev/null || true
    else
        echo "Chrome is NOT running on CDP port $CDP_PORT"
    fi
}

open_urls() {
    local urls=("$@")
    if [[ ${#urls[@]} -eq 0 ]]; then
        return
    fi
    sleep 2
    for url in "${urls[@]}"; do
        # Percent-encode: an unencoded '#' would be dropped as a fragment, taking
        # hash-router paths with it, and spaces would break the request line.
        local encoded
        encoded=$(URL="$url" python3 -c \
            'import os, urllib.parse; print(urllib.parse.quote(os.environ["URL"], safe=""))')
        # /json/new accepts PUT only (Chrome 111+); GET returns an error string.
        if curl -s -X PUT "http://localhost:$CDP_PORT/json/new?${encoded}" | grep -q webSocketDebuggerUrl; then
            echo "    Opened: $url"
        else
            echo "    WARNING: failed to open $url"
        fi
        sleep 0.5
    done
}

# ── Handle --stop ────────────────────────────────────────────────────────

if [[ "${1:-}" == "--stop" ]]; then
    if chrome_running; then
        # Match our own profile first; fall back to any browser bound to our CDP
        # port. Never fall back to "whoever holds the port" — that could be an
        # unrelated process.
        PIDS=$(pgrep -f "user-data-dir=$CHROME_PROFILE" 2>/dev/null || true)
        if [[ -z "$PIDS" ]]; then
            PIDS=$(pgrep -f -- "--remote-debugging-port=$CDP_PORT" 2>/dev/null || true)
        fi
        if [[ -n "$PIDS" ]]; then
            echo "$PIDS" | xargs kill 2>/dev/null || true
            echo "Sent SIGTERM to Chrome (PIDs: $( echo "$PIDS" | tr '\n' ' '))"
            for _ in $(seq 1 10); do
                if ! chrome_running; then
                    echo "Chrome stopped cleanly (cookies saved; tabs are not restored)"
                    exit 0
                fi
                sleep 1
            done
            echo "Warning: Chrome did not stop within 10s"
        fi
    else
        echo "No Chrome running on port $CDP_PORT"
    fi
    exit 0
fi

# ── Handle --status ──────────────────────────────────────────────────────

if [[ "${1:-}" == "--status" ]]; then
    print_status
    exit 0
fi

# ── Handle --login ───────────────────────────────────────────────────────

LOGIN_MODE=false
if [[ "${1:-}" == "--login" ]]; then
    LOGIN_MODE=true
    shift
fi

# ── Collect URLs from remaining args ─────────────────────────────────────

URLS=()
for arg in "$@"; do
    if [[ "$arg" == http* ]]; then
        URLS+=("$arg")
    fi
done

# ── Already running? ─────────────────────────────────────────────────────

if chrome_running; then
    echo "Chrome already running on CDP port $CDP_PORT"
    if [[ ${#URLS[@]} -gt 0 ]]; then
        echo "  Opening requested URLs..."
        open_urls "${URLS[@]}"
    fi
    if [[ "$LOGIN_MODE" == "true" ]]; then
        echo ""
        echo "=== LOGIN MODE === Chrome is already running. Log in in the open window;"
        echo "the session is saved to the persistent profile automatically."
    fi
    print_status
    exit 0
fi

# ── Find Chrome ──────────────────────────────────────────────────────────

CHROME=$(find_chrome_binary)
if [[ -z "$CHROME" ]]; then
    echo "ERROR: Google Chrome not found."
    exit 1
fi

# ── Create profile dir if needed ─────────────────────────────────────────

if [[ ! -d "$CHROME_PROFILE" ]]; then
    mkdir -p "$CHROME_PROFILE"
    echo "Created fresh Chrome profile at $CHROME_PROFILE"
fi

# ── Disable App Nap on macOS ─────────────────────────────────────────────

if [[ "$(uname)" == "Darwin" ]]; then
    defaults write com.google.Chrome NSAppSleepDisabled -bool YES 2>/dev/null || true
fi

# ── Start clean: never restore the previous session's tabs ───────────────
# Auth persists via cookies in the profile, NOT via session restore. Restoring
# tabs only accumulates leftovers across runs.
#   restore_on_startup=5 → open the new-tab page (SessionStartupPref: 1=restore
#                          last session, 4=URL list, 5=NTP — do NOT "simplify" to 1)
#   exit_type=Normal     → suppress the "Restore pages?" crash bubble after SIGTERM
# Official Chrome may discard this write (tracked-preference MACs); dropping the
# --restore-last-session flag is what actually stops the pile-up. This is the
# belt-and-braces for Chromium builds, where the write IS honoured.

if [[ -f "$CHROME_PROFILE/Default/Preferences" ]]; then
    PREFS_PATH="$CHROME_PROFILE/Default/Preferences" python3 -c "
import json, os, sys
path = os.environ['PREFS_PATH']
try:
    with open(path) as f:
        prefs = json.load(f)
    session = prefs.setdefault('session', {})
    session['restore_on_startup'] = 5
    session.pop('startup_urls', None)
    profile = prefs.setdefault('profile', {})
    profile['exit_type'] = 'Normal'
    profile['exited_cleanly'] = True
    tmp = path + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(prefs, f)
    os.replace(tmp, path)   # atomic: never leave a truncated Preferences file
except Exception as e:
    print(f'Warning: could not reset session preferences: {e}', file=sys.stderr)
"
fi

# ── Chrome flags ─────────────────────────────────────────────────────────

CHROME_FLAGS=(
    --user-data-dir="$CHROME_PROFILE"
    --remote-debugging-port="$CDP_PORT"
    --disable-session-crashed-bubble
    --hide-crash-restore-bubble
    --disable-background-timer-throttling
    --disable-renderer-backgrounding
    --disable-backgrounding-occluded-windows
    --no-first-run
    --no-default-browser-check
    --disable-popup-blocking
)

echo "Launching Chrome..."
echo "  Profile: $CHROME_PROFILE"
echo "  CDP port: $CDP_PORT"

nohup "$CHROME" "${CHROME_FLAGS[@]}" > /dev/null 2>&1 &
CHROME_PID=$!

# ── Wait for CDP ─────────────────────────────────────────────────────────

echo "  Waiting for CDP..."
for _ in $(seq 1 30); do
    if chrome_running; then
        echo "  Chrome ready (PID: $CHROME_PID)"
        break
    fi
    sleep 1
done

if ! chrome_running; then
    echo "ERROR: Chrome failed to start within 30s."
    kill "$CHROME_PID" 2>/dev/null || true
    exit 1
fi

# ── Open requested URLs ──────────────────────────────────────────────────

if [[ ${#URLS[@]} -gt 0 ]]; then
    echo "  Opening requested URLs..."
    open_urls "${URLS[@]}"
fi

# ── Login mode ───────────────────────────────────────────────────────────

if [[ "$LOGIN_MODE" == "true" ]]; then
    echo ""
    echo "=== LOGIN MODE ==="
    echo "Chrome is open. Log in to any sites you need — cookies are saved to the"
    echo "persistent profile at $CHROME_PROFILE and survive restarts."
    echo "Chrome stays running on port $CDP_PORT."
fi

print_status
exit 0
