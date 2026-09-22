#!/usr/bin/env bash
# setup_chrome.sh — Launch/stop the skill's Chrome (headless by default) with CDP.
#
# Headless so it never opens a window or steals focus from the user; the UA is
# rewritten to what the same binary sends headed, so sites that block
# "HeadlessChrome" still work. --login (and BT_HEADED=1) run headed instead.
#
# Idempotent: won't start a second Chrome if ours already answers on the CDP port,
# and REFUSES a port that answers CDP but isn't running our profile (another
# project's browser, a foreign CDP service) — attaching to it silently is the
# one failure that looks like success.
#
# Usage:
#   setup_chrome.sh              # Start Chrome (headless)
#   setup_chrome.sh --ensure     # Same, silent when already running (used by connect.py)
#   setup_chrome.sh --stop       # Graceful stop (cookies persist, tabs do not)
#   setup_chrome.sh --login URL  # Start HEADED Chrome, open URL for manual login
#   setup_chrome.sh --status     # Is Chrome running, and is it ours?
#   setup_chrome.sh URL [URL...] # Start Chrome and open URLs
#
# Environment (`bt` derives the first two per project — see bt):
#   CDP_PORT=NNNN          CDP port
#   BT_CHROME_PROFILE=DIR  Profile dir (cookies/logins persist here)
#   BT_HEADED=1            Visible window instead of headless
#   CHROME_BIN=PATH        Override browser binary (any Chromium-based browser)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
CHROME_PROFILE="${BT_CHROME_PROFILE:-$HOME/.claude/browser-testing-profiles/default}"
CDP_PORT="${CDP_PORT:-9340}"
CDP_URL="http://127.0.0.1:$CDP_PORT"

# ── Helpers ──────────────────────────────────────────────────────────────

# Strict: a real CDP endpoint, not merely something answering HTTP on the port.
chrome_running() {
    [[ "$(curl -fsS --max-time 2 "$CDP_URL/json/version" 2>/dev/null)" == *webSocketDebuggerUrl* ]]
}

# pgrep -f matches an ERE against the full command line: escape the path and
# anchor it on the next flag (every Chrome arg starts with --), or .../proj also
# matches .../proj-staging and ".../proj staging".
re_escape() {
    local s="$1" c
    s="${s//\\/\\\\}"
    for c in '.' '*' '+' '?' '(' ')' '[' ']' '{' '}' '|' '^' '$'; do
        s="${s//"$c"/\\$c}"
    done
    printf '%s' "$s"
}
PROFILE_RE="user-data-dir=$(re_escape "$CHROME_PROFILE")( --|$)"
# Our launch line puts the port right after the profile (see CHROME_FLAGS).
OWN_RE="user-data-dir=$(re_escape "$CHROME_PROFILE") --remote-debugging-port=$CDP_PORT( --|$)"

# Every process of a Chrome on our profile (helpers carry --user-data-dir too).
our_pids() { pgrep -f "$PROFILE_RE" 2>/dev/null || true; }
# Only the browser processes (helpers have --type=); the ones that own the CDP
# port and take SIGTERM as a normal shutdown.
our_browser_pids() {
    local p
    for p in $(our_pids); do
        [[ "$(ps -o args= -p "$p" 2>/dev/null)" == *" --type="* ]] || echo "$p"
    done
}

# Does OUR browser own CDP_PORT? Ours = a browser process launched with our profile
# AND this port on its command line (flag order is ours, see CHROME_FLAGS). lsof
# then vetoes the one case the command line can't see: our Chrome lost the bind
# race and a foreign browser is the one actually listening. An empty lsof answer
# while something clearly listens means lsof failed, not "foreign".
port_is_ours() {
    local ours owner
    ours="$(pgrep -f "$OWN_RE" 2>/dev/null || true)"
    [[ -n "$ours" ]] || return 1
    if command -v lsof &>/dev/null; then
        owner="$(lsof -nP -iTCP@127.0.0.1:"$CDP_PORT" -sTCP:LISTEN -t 2>/dev/null | head -1 || true)"
        [[ -z "$owner" ]] || grep -qx "$owner" <<< "$ours"
    fi
    # ponytail: without lsof the bind-race case attaches to the foreign browser.
}

refuse_foreign() {
    if chrome_running && ! port_is_ours; then
        echo "ERROR: port $CDP_PORT answers CDP, but no Chrome is running our profile" >&2
        echo "       $CHROME_PROFILE" >&2
        echo "       Another project's browser (or a foreign CDP service) holds the port." >&2
        echo "       Set CDP_PORT to a free port for this session, or stop that browser." >&2
        exit 1
    fi
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

# Headless Chrome announces itself as "HeadlessChrome/N", which some sites reject.
# Rebuild the UA the same binary sends when headed: Chrome's reduced UA is a frozen
# platform token plus the major version only, so this stays true across updates.
real_chrome_ua() {
    local major platform="X11; Linux x86_64"
    # Last 4-part version on the line: Brave prints "Brave Browser 1.83.109 Chromium: 153.0.…".
    major="$("$CHROME" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tail -1 | cut -d. -f1 || true)"
    [[ -n "$major" ]] || return 1     # unknown → keep the browser's own UA rather than lie
    [[ "$(uname)" == "Darwin" ]] && platform="Macintosh; Intel Mac OS X 10_15_7"
    echo "Mozilla/5.0 ($platform) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/$major.0.0.0 Safari/537.36"
}

# Ask the browser to close itself over CDP. A bare SIGTERM is recorded as an
# abnormal exit and macOS raises a "quit unexpectedly" dialog — which steals focus
# exactly like the window we removed. Needs the venv's playwright; the caller falls
# back to SIGTERM when this returns non-zero.
graceful_close() {
    local py="$SKILL_DIR/.venv/bin/python"
    [[ -x "$py" ]] || return 1
    CDP_URL="$CDP_URL" "$py" - <<'PY' >/dev/null 2>&1
import asyncio, os
from playwright.async_api import async_playwright

async def main():
    async with async_playwright() as pw:
        b = await pw.chromium.connect_over_cdp(os.environ["CDP_URL"], timeout=3000)
        s = await b.new_browser_cdp_session()
        try:
            await s.send("Browser.close")
        except Exception:
            pass  # the connection drops as the browser exits

try:
    asyncio.run(main())
except Exception:
    pass
PY
}

print_status() {
    [[ -n "${BT_PROJECT_ROOT:-}" ]] && echo "Project root: $BT_PROJECT_ROOT"
    echo "Profile:  $CHROME_PROFILE"
    echo "CDP port: $CDP_PORT"
    if chrome_running; then
        if port_is_ours; then
            echo "Chrome is RUNNING on CDP port $CDP_PORT (ours)"
        else
            echo "Chrome is RUNNING on CDP port $CDP_PORT but is NOT OURS — another"
            echo "  project's browser or a foreign CDP service. Set CDP_PORT to use a free port."
            return
        fi
        curl -s "$CDP_URL/json/version" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(f\"  Browser: {data.get('Browser', 'unknown')}\")
print(f\"  WebSocket: {data.get('webSocketDebuggerUrl', 'unknown')}\")
" 2>/dev/null || true
        echo "  Tabs:"
        curl -s "$CDP_URL/json" | python3 -c "
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
        if [[ "$(curl -s -X PUT "$CDP_URL/json/new?${encoded}")" == *webSocketDebuggerUrl* ]]; then
            echo "    Opened: $url"
        else
            echo "    WARNING: failed to open $url"
        fi
        sleep 0.5
    done
}

stop_ours() {
    # Profile first, regardless of CDP health: a dead port must not prevent
    # stopping a live Chrome. Never kill by port — that could be someone else's.
    local pids
    pids="$(our_pids)"
    if [[ -z "$pids" ]]; then
        if chrome_running; then
            echo "Port $CDP_PORT is held by a browser that is not ours — leaving it alone"
        else
            echo "No Chrome running on profile $CHROME_PROFILE"
        fi
        return 0
    fi
    if chrome_running && port_is_ours; then
        graceful_close || true
        for _ in $(seq 1 8); do
            if [[ -z "$(our_pids)" ]]; then
                echo "Chrome closed gracefully (cookies saved; tabs are not restored)"
                return 0
            fi
            sleep 1
        done
    fi
    # Signal the browser process only: it shuts its helpers down in order. Killing
    # the helpers underneath it is what makes it abort — and macOS report a crash.
    pids="$(our_browser_pids)"
    echo "$pids" | xargs kill 2>/dev/null || true
    echo "Sent SIGTERM to Chrome (PIDs: $(echo "$pids" | tr '\n' ' '))"
    for _ in $(seq 1 10); do
        if [[ -z "$(our_pids)" ]]; then
            echo "Chrome stopped (cookies saved; tabs are not restored)"
            return 0
        fi
        sleep 1
    done
    echo "Warning: Chrome did not stop within 10s"
    return 0
}

# ── Handle --stop / --status ─────────────────────────────────────────────

case "${1:-}" in
    --stop)   stop_ours; exit 0 ;;
    --status) print_status; exit 0 ;;
esac

# ── Handle --login / --ensure ────────────────────────────────────────────

LOGIN_MODE=false
ENSURE_MODE=false
case "${1:-}" in
    --login)  LOGIN_MODE=true; shift ;;
    --ensure) ENSURE_MODE=true; shift ;;
esac

HEADED=false
if [[ "$LOGIN_MODE" == "true" || "${BT_HEADED:-}" == "1" ]]; then
    HEADED=true
fi

# ── Collect URLs from remaining args ─────────────────────────────────────

URLS=()
for arg in "$@"; do
    if [[ "$arg" == http* ]]; then
        URLS+=("$arg")
    fi
done

# ── Already running? ─────────────────────────────────────────────────────

refuse_foreign

if chrome_running; then
    if [[ "$ENSURE_MODE" == "true" ]]; then
        exit 0
    fi
    if [[ "$LOGIN_MODE" == "true" ]]; then
        # Login needs a visible window, and Chrome won't start twice on one
        # profile — swap the running (headless) instance for a headed one.
        echo "Stopping the running Chrome to relaunch it headed for login..."
        stop_ours
    else
        echo "Chrome already running on CDP port $CDP_PORT"
        if [[ ${#URLS[@]} -gt 0 ]]; then
            echo "  Opening requested URLs..."
            open_urls "${URLS[@]}"
        fi
        print_status
        exit 0
    fi
fi

# ── Find Chrome ──────────────────────────────────────────────────────────

CHROME=$(find_chrome_binary)
if [[ -z "$CHROME" ]]; then
    echo "ERROR: Google Chrome not found."
    exit 1
fi

# ── Create profile dir if needed ─────────────────────────────────────────

if [[ ! -d "$CHROME_PROFILE" ]]; then
    mkdir -p "$(dirname "$CHROME_PROFILE")"
    mkdir -m 700 "$CHROME_PROFILE"      # cookies live here
    echo "Created fresh Chrome profile at $CHROME_PROFILE"
    if [[ -d "$SKILL_DIR/config/chrome-profile" ]]; then
        echo "  NOTE: profiles are per project now. Logins saved in the old shared profile"
        echo "  ($SKILL_DIR/config/chrome-profile) are not carried over — run --login once."
    fi
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
if [[ "$HEADED" == "false" ]]; then
    # No window: nothing to steal focus, nothing to minimise, and screenshots come
    # out at 1× instead of the Retina 2× that used to trip the size guard.
    CHROME_FLAGS+=(--headless=new "--window-size=1280,900")
    if UA="$(real_chrome_ua)"; then
        CHROME_FLAGS+=("--user-agent=$UA")
    fi
fi

echo "Launching Chrome ($([[ "$HEADED" == "true" ]] && echo headed || echo headless))..."
echo "  Profile: $CHROME_PROFILE"
echo "  CDP port: $CDP_PORT"

nohup "$CHROME" "${CHROME_FLAGS[@]}" > /dev/null 2>&1 &
CHROME_PID=$!

# ── Wait for CDP ─────────────────────────────────────────────────────────

echo "  Waiting for CDP..."
READY=false
for _ in $(seq 1 30); do
    if chrome_running; then
        # A foreign browser can win the port during this wait (1-in-60 hash
        # collision, two projects launching together). Ours then runs without CDP
        # and attaching would silently drive the other project's browser.
        if ! port_is_ours; then
            echo "ERROR: port $CDP_PORT was taken by a browser that is not ours while starting." >&2
            echo "       Set CDP_PORT to a free port for this session." >&2
            kill "$CHROME_PID" 2>/dev/null || true
            exit 1
        fi
        echo "  Chrome ready (PID: $CHROME_PID)"
        READY=true
        break
    fi
    sleep 1
done

if [[ "$READY" == "false" ]]; then
    if [[ -n "$(our_browser_pids)" ]]; then
        # Chrome's singleton: an instance on this profile already runs (on another
        # port, or a --login swap whose stop timed out) and the new one deferred to it.
        echo "ERROR: a Chrome is already running on profile $CHROME_PROFILE but does not" >&2
        echo "       answer on port $CDP_PORT. Run --stop, or check CDP_PORT." >&2
    else
        echo "ERROR: Chrome failed to start within 30s." >&2
    fi
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
    echo "A visible Chrome window is open. Log in to any sites you need — cookies are"
    echo "saved to the persistent profile at $CHROME_PROFILE and survive restarts."
    echo "When done, run --stop; the next command relaunches Chrome headless."
fi

if [[ "$ENSURE_MODE" == "false" ]]; then
    print_status
fi
exit 0
