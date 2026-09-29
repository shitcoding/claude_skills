#!/usr/bin/env bash
# Claude Code status line: tee the payload to disk for skills, then render it.
#
# Claude Code pipes a JSON payload to the status line command on stdin. It contains
# context_window.used_percentage (pre-calculated by Claude Code itself), the raw token
# counts, the context window size, the session id and the transcript path — everything a
# skill needs, without scraping the rendered bar out of a tmux pane.
#
# Wire up in ~/.claude/settings.json:
#   "statusLine": {
#     "type": "command",
#     "command": "$HOME/.claude/skills/ctx-usage/scripts/statusline.sh",
#     "padding": 0
#   }
#
# Env: CLAUDE_CTX_DIR (payload directory, default ~/.claude/ctx)
#      CTX_RENDER     (renderer command, default: an installed `ccstatusline`, else
#                      `bunx -y ccstatusline@latest`)
#
# Install the renderer once (`npm install -g ccstatusline`, update with `npm update -g
# ccstatusline`). The bunx fallback re-resolves and re-downloads the package on every
# render — ~0.6 s, a registry round-trip and a freshly written script for Gatekeeper to
# scan, per refresh, per open session — versus ~0.2 s and no network when installed.
#
# NOTE: deliberately no `set -e` and no `set -o pipefail` — a failure in the tee must
# never blank the user's status line. The exit status is the renderer's, as it would be
# without this wrapper.

input=$(cat)

{
  dir="${CLAUDE_CTX_DIR:-$HOME/.claude/ctx}"
  mkdir -p "$dir" && chmod 700 "$dir"
  sid=$(printf '%s' "$input" | jq -r '.session_id // empty')
  if [ -n "$sid" ]; then
    # First render of a session: drop payloads for sessions untouched for two weeks.
    # ponytail: cheap once-per-session prune, no cron. Files are ~4 KB each.
    [ -f "$dir/$sid.json" ] || find "$dir" -name '*.json' -mtime +14 -delete
    # Write-then-rename: Claude Code aborts the in-flight status line process on every
    # re-render, so a plain `>` could leave a reader holding a truncated file.
    tmp="$dir/$sid.json.tmp"
    printf '%s' "$input" >"$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$dir/$sid.json"
  fi
} 2>/dev/null || true

render=${CTX_RENDER:-}
if [ -z "$render" ]; then
  if command -v ccstatusline >/dev/null 2>&1; then render=ccstatusline
  else render='bunx -y ccstatusline@latest'; fi
fi
printf '%s' "$input" | $render
