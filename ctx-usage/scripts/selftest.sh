#!/usr/bin/env bash
# Self-check: feed a known payload through statusline.sh and assert what ctx reports.
# Uses a scratch payload dir and a stub renderer — never touches ~/.claude or the real bar.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export CLAUDE_CTX_DIR="$tmp/ctx"
export CLAUDE_CODE_SESSION_ID="00000000-1111-2222-3333-444444444444"
export CTX_RENDER="cat"

# 4000 + 6000 + 416000 = 426000 of 1000000 -> 42.6% exact, 43% as Claude Code rounds it.
payload='{"session_id":"'"$CLAUDE_CODE_SESSION_ID"'","transcript_path":"/tmp/x.jsonl",
  "context_window":{"total_input_tokens":426000,"total_output_tokens":120,
  "context_window_size":1000000,
  "current_usage":{"input_tokens":4000,"output_tokens":120,
    "cache_creation_input_tokens":6000,"cache_read_input_tokens":416000},
  "used_percentage":43,"remaining_percentage":57}}'

check() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "ok   $label -> $actual"
  else
    echo "FAIL $label: expected '$expected', got '$actual'" >&2
    exit 1
  fi
}

# The renderer still receives the payload unchanged.
rendered="$(printf '%s' "$payload" | "$here/statusline.sh" | jq -r '.session_id')"
check "payload reaches renderer" "$CLAUDE_CODE_SESSION_ID" "$rendered"

f="$CLAUDE_CTX_DIR/$CLAUDE_CODE_SESSION_ID.json"
[ -s "$f" ] || { echo "FAIL: payload was not tee'd to $f" >&2; exit 1; }
echo "ok   tee'd to \$CLAUDE_CTX_DIR/<session-id>.json"

check "dir mode"  "700" "$(stat -f '%OLp' "$CLAUDE_CTX_DIR" 2>/dev/null || stat -c '%a' "$CLAUDE_CTX_DIR")"
check "file mode" "600" "$(stat -f '%OLp' "$f" 2>/dev/null || stat -c '%a' "$f")"
check "no temp file left" "" "$(find "$CLAUDE_CTX_DIR" -name '*.tmp' -print)"

check "--pct"    "43"     "$("$here/ctx")"
check "--exact"  "42.6"   "$("$here/ctx" --exact)"
check "--tokens" "426000" "$("$here/ctx" --tokens)"

# A session with no API response yet must fail, not report 0.
printf '%s' '{"session_id":"'"$CLAUDE_CODE_SESSION_ID"'","context_window":{"context_window_size":1000000,"current_usage":null,"used_percentage":null,"remaining_percentage":null}}' \
  | "$here/statusline.sh" >/dev/null
if "$here/ctx" >/dev/null 2>&1; then
  echo "FAIL: ctx reported a value for a session with no usage yet" >&2; exit 1
fi
echo "ok   no usage yet -> non-zero exit, no bogus 0"

# A missing payload must fail fast, so callers fall back instead of trusting a stale read.
rm -f "$f"
if CLAUDE_CTX_DIR="$tmp/ctx" "$here/ctx" >/dev/null 2>&1; then
  echo "FAIL: ctx succeeded with no payload file" >&2; exit 1
fi
echo "ok   missing payload -> non-zero exit"

echo "all checks passed"
