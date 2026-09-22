#!/usr/bin/env bash
# check-bt.sh — the one runnable check for the browser-testing skill.
#
# Offline: per-project derivation (profile + port), overrides, port range.
# Live (needs Chrome): headless launch steals no focus, UA is not HeadlessChrome,
# ownership guard refuses a foreign profile on our port, one-shot calls leave no
# tabs behind, --python flows close their tabs unless keep_pages=True, --snapshot
# prints roles, --stop is graceful. Uses a throwaway profile on port 9397 — never
# your real profiles. Headed mode is NOT exercised: it would pop a window.
#
#   bash check-bt.sh          # everything
#   BT_CHECK_OFFLINE=1 …      # derivation only
# shellcheck disable=SC2016,SC2034,SC2329  # assertions are eval strings
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
BT="$SKILL_DIR/scripts/bt"
# Never inherit a real session's overrides: an inherited BT_CHROME_PROFILE would make
# the --stop assertions below stop a real browser.
unset CDP_PORT BT_CHROME_PROFILE BT_HEADED BT_PROJECT_ROOT
TMP="$(mktemp -d)" || { echo "mktemp failed"; exit 1; }
PORT=9397
PASS=0; FAIL=0

ok()   { PASS=$((PASS + 1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }

cleanup() {
    # Guarded: with an empty TMP this pkill would match every Chrome on the machine.
    [[ -n "$TMP" && -d "$TMP" ]] || return 0
    pkill -f "user-data-dir=$TMP/" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

# ── Offline: derivation ──────────────────────────────────────────────────
echo "derivation"
mkdir -p "$TMP/projA" "$TMP/projB"
git -C "$TMP/projA" init -q; git -C "$TMP/projB" init -q
mkdir -p "$TMP/projA/deep/er"
status_of() { (cd "$1" && "$BT" --status 2>/dev/null); }
A="$(status_of "$TMP/projA")"; B="$(status_of "$TMP/projB")"; A2="$(status_of "$TMP/projA/deep/er")"
portA="$(sed -n 's/^CDP port: //p' <<< "$A")"; portB="$(sed -n 's/^CDP port: //p' <<< "$B")"
profA="$(sed -n 's/^Profile:  //p' <<< "$A")"; profB="$(sed -n 's/^Profile:  //p' <<< "$B")"
check "same git root → same profile and port from a subdir" '[[ "$A" == "$A2" ]]'
check "different roots → different profiles" '[[ -n "$profA" && "$profA" != "$profB" ]]'
check "profile lives under ~/.claude/browser-testing-profiles/<basename>-<6hex>" \
    '[[ "$profA" =~ ^$HOME/\.claude/browser-testing-profiles/projA-[0-9a-f]{6}$ ]]'
check "port in 9340–9399 (never legacy 9333)" '[[ "$portA" -ge 9340 && "$portA" -le 9399 ]]'
check "CDP_PORT override wins" \
    '[[ "$(cd "$TMP/projA" && CDP_PORT=9999 "$BT" --status | sed -n "s/^CDP port: //p")" == 9999 ]]'
check "BT_CHROME_PROFILE override wins" \
    '[[ "$(cd "$TMP/projA" && BT_CHROME_PROFILE=/x/y "$BT" --status | sed -n "s/^Profile:  //p")" == /x/y ]]'
check "--stop with nothing running exits 0" '(cd "$TMP/projA" && "$BT" --stop >/dev/null)'
if command -v shellcheck >/dev/null; then
    check "shellcheck clean" 'shellcheck "$BT" "$SKILL_DIR/scripts/setup_chrome.sh"'
else
    echo "  skip shellcheck (not installed)"
fi

if [[ -n "${BT_CHECK_OFFLINE:-}" ]]; then
    echo "passed $PASS, failed $FAIL (offline only)"; exit $((FAIL > 0))
fi

# ── Live: headless round-trip on a throwaway profile ─────────────────────
echo "live (port $PORT, profile $TMP/prof)"
export CDP_PORT=$PORT BT_CHROME_PROFILE="$TMP/prof"
cat > "$TMP/page.html" <<'HTML'
<!doctype html><title>bt check</title><h1>Hello</h1>
<form><label>Email <input name="email"></label><button type="submit">Save changes</button></form>
<a href="#next">Next page</a>
HTML
export PAGE="file://$TMP/page.html"

# Frontmost app name and pid (macOS; empty elsewhere — those checks then pass vacuously).
front() { osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null; }
front_pid() { osascript -e 'tell application "System Events" to get unix id of first application process whose frontmost is true' 2>/dev/null; }
ours_cmdlines() { for p in $(pgrep -f "user-data-dir=$TMP/prof"); do ps -o args= -p "$p"; done; }
out="$("$BT" --start 2>&1)"
check "launches headless" '[[ "$out" == *"Launching Chrome (headless)"* && "$(ours_cmdlines)" == *"--headless=new"* ]]'
if [[ -n "$(front_pid)" ]]; then
    check "our Chrome is not the frontmost app (frontmost: $(front))" '! pgrep -f "user-data-dir=$TMP/prof" | grep -qx "$(front_pid)"'
else
    echo "  skip focus assertion (osascript unavailable or denied)"
fi
ua="$("$BT" "$PAGE" --eval 'navigator.userAgent' 2>/dev/null)"
check "UA is not HeadlessChrome: ${ua##*) }" '[[ "$ua" == *"Chrome/"* && "$ua" != *Headless* ]]'
brands="$("$BT" "$PAGE" --eval '(navigator.userAgentData||{brands:[]}).brands.map(b=>b.brand).join("|")' 2>/dev/null)"
check "client-hint brands don't say Headless: ${brands:-none}" '[[ "$brands" != *Headless* ]]'

snap="$("$BT" "$PAGE" --snapshot 2>/dev/null)"
check "--snapshot prints roles + names" 'grep -q "button \"Save changes\"" <<< "$snap" && grep -q "textbox \"Email\"" <<< "$snap"'
tabs="$("$BT" --tabs 2>/dev/null)"
check "one-shot calls leave no page tab behind" '! grep -q "page.html" <<< "$tabs"'
check "…but keep Chrome alive (one blank tab)" 'grep -q "Open Tabs (1)" <<< "$tabs"'

"$BT" --python -c "
import asyncio, os
from connect import Browser
async def main():
    async with Browser() as b:
        p = await b.get_page(os.environ['PAGE'])
        await b.fill(p, 'role=textbox[name=\"Email\"]', 'a@b.c')
        print('filled:', await b.evaluate(p, 'document.querySelector(\"input\").value'))
asyncio.run(main())" >"$TMP/py.out" 2>&1
check "--python: role= selector works on the snapshot's names" 'grep -q "filled: a@b.c" "$TMP/py.out"'
check "--python: tab closed on exit" '[[ "$("$BT" --tabs 2>/dev/null)" != *page.html* ]]'
"$BT" --python -c "
import asyncio, os
from connect import Browser
async def main():
    async with Browser(keep_pages=True) as b:
        await b.get_page(os.environ['PAGE'])
asyncio.run(main())" >/dev/null 2>&1
check "--python keep_pages=True: tab survives" '[[ "$("$BT" --tabs 2>/dev/null)" == *page.html* ]]'
"$BT" --close-others >/dev/null 2>&1

# Ownership guard: same port, a different profile → must refuse, must not attach.
err="$(cd "$TMP/projA" && BT_CHROME_PROFILE="$TMP/other" "$BT" "$PAGE" 2>&1 >/dev/null)"
check "foreign profile on our port is refused (bt URL)" 'grep -q "not.*running our profile\|no Chrome is running our profile" <<< "$err" && grep -q "CDP_PORT" <<< "$err"'
check "--status names it NOT OURS" '[[ "$(BT_CHROME_PROFILE="$TMP/other" "$BT" --status)" == *"NOT OURS"* ]]'
check "--stop from the foreign profile leaves our Chrome alone" '[[ "$(BT_CHROME_PROFILE="$TMP/other" "$BT" --stop)" == *"leaving it alone"* ]] && curl -fsS "http://127.0.0.1:$PORT/json/version" >/dev/null'

out="$("$BT" --stop 2>&1)"
check "--stop closes gracefully via CDP" '[[ "$out" == *"closed gracefully"* ]]'
check "no process left on the profile" '[[ -z "$(pgrep -f "user-data-dir=$TMP/prof")" ]]'
check "stop raised no crash dialog (frontmost: $(front))" '[[ "$(front)" != "Problem Reporter" ]]'

# SIGTERM fallback (no venv → no graceful path): only the browser process is signalled.
"$BT" --start >/dev/null 2>&1
mv "$SKILL_DIR/.venv" "$SKILL_DIR/.venv.check-hidden"
out="$(bash "$SKILL_DIR/scripts/setup_chrome.sh" --stop 2>&1)"
mv "$SKILL_DIR/.venv.check-hidden" "$SKILL_DIR/.venv"
check "SIGTERM fallback signals exactly one pid (the browser, not its helpers)" '[[ "$out" == *"Sent SIGTERM to Chrome (PIDs: "* && "$(grep -oE "PIDs: [0-9 ]+" <<< "$out" | wc -w)" -eq 2 ]]'
check "…and Chrome is gone" '[[ -z "$(pgrep -f "user-data-dir=$TMP/prof")" ]]'
check "…with no crash dialog (frontmost: $(front))" '[[ "$(front)" != "Problem Reporter" ]]'

echo "passed $PASS, failed $FAIL"
exit $((FAIL > 0))
