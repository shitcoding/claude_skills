---
name: ctx-usage
description: Read the current Claude Code session's context-window usage (percent and raw tokens) from the status line payload instead of scraping the rendered status bar. Use when a skill or script needs to know how full the context is — context thresholds, handover triggers, session naming.
---

# ctx-usage

Claude Code pipes a JSON payload to the status line command on stdin, and that payload
already contains the context usage — **pre-calculated by Claude Code itself**:

```json
"context_window": {
  "total_input_tokens": 426000,
  "total_output_tokens": 120,
  "context_window_size": 1000000,
  "current_usage": { "input_tokens": 4000, "output_tokens": 120,
                     "cache_creation_input_tokens": 6000,
                     "cache_read_input_tokens": 416000 },
  "used_percentage": 43,
  "remaining_percentage": 57
}
```

Status line plugins (ccstatusline and friends) just print `used_percentage`. This skill
captures the same payload to disk so scripts can read the number directly, rather than
running `tmux capture-pane` and regexing the rendered bar.

`statusline.sh` wraps whatever renderer you already use: it tees the payload, then pipes
it through unchanged. The bar looks exactly the same.

## Prerequisites

- `jq`
- A status line renderer. The default is `bunx -y ccstatusline@latest`; override with
  `CTX_RENDER`.

## Quick Start

Install the skill (symlink its directory into `~/.claude/skills/`), then point the status
line at the wrapper in `~/.claude/settings.json`:

```json
"statusLine": {
  "type": "command",
  "command": "$HOME/.claude/skills/ctx-usage/scripts/statusline.sh",
  "padding": 0
}
```

The command runs through a shell, so `$HOME` expands. Use the path where you actually
installed the skill.

Then, from any script or Bash tool call inside a session:

```bash
ctx            # 43      — integer percent, identical to the status bar
ctx --exact    # 42.6    — one decimal, computed from the raw token counts
ctx --tokens   # 426000  — context tokens in use
ctx --json     # the whole payload (session_id, transcript_path, model, rate_limits, …)
```

## How it finds the right session

The payload is written to `~/.claude/ctx/<session-id>.json`, and readers key off
`$CLAUDE_CODE_SESSION_ID` — which Claude Code sets in every Bash tool environment and
which equals the transcript filename stem in `~/.claude/projects/<slug>/`.

That is an exact join. Do **not** key this by `$TMUX_PANE` (pane ids are reused and reset
when the tmux server restarts, and non-tmux sessions have none) or by "newest `.jsonl` by
mtime" (with several sessions open it silently resolves to a sibling session).

Note the variable name: `CLAUDE_CODE_SESSION_ID`. `CLAUDE_SESSION_ID` and
`CLAUDE_PROJECT_DIR` are **not** set in a Bash tool shell.

## Configuration

| Env | Default | Meaning |
|-----|---------|---------|
| `CLAUDE_CTX_DIR` | `~/.claude/ctx` | Where payloads are written and read |
| `CTX_RENDER` | `bunx -y ccstatusline@latest` | The status line renderer to wrap |

The payload directory is `0700` and payloads are `0600` — they carry the session id,
transcript path, cwd, repo and subscription rate limits. On the first render of each
session, payloads untouched for 14 days are pruned.

## Notes

- **`used_percentage` is an integer.** Claude Code computes
  `clamp(round((input + cache_creation + cache_read) / context_window_size * 100), 0, 100)`
  from the last message carrying usage. Output tokens are excluded (they become input
  tokens on the next turn). A status line showing `43.0%` is a one-decimal render of an
  int — use `--exact` if you need finer granularity for a threshold.
- **Freshness.** The render is debounced ~300ms behind the message that triggers it, and
  Claude Code aborts an in-flight status line process when a new render starts. The
  payload is written before the renderer runs, so it is never staler than the bar; `ctx`
  retries 5×0.3s to cover the debounce. The write is temp-then-rename, so a reader can
  never catch a half-written file.
- **Exit codes matter.** `ctx` exits non-zero when there is no payload, or when the
  session has not had an API response yet (`used_percentage: null`). Callers must fall
  back rather than treat a failure as `0`.
- **Context window size cannot be recovered from the transcript.** Transcript entries
  record `message.model` as e.g. `claude-opus-5` with no `[1m]` marker, so a
  transcript-only reader cannot tell a 1M session from a 200k one. The payload's
  `context_window_size` is the only reliable source.
- **Auto-compact** fires when context tokens reach `usable - 13000`, where
  `usable = context_window_size - min(max_output_tokens, 20000)` — roughly 96% of a 1M
  window and 83% of a 200k one. (Claude Code precomputes the compaction summary earlier,
  at about 78% of a 1M window.) Thresholds below that are safely clear of it.
- Verify with `scripts/selftest.sh` — it runs the payload through the wrapper with a stub
  renderer and a scratch directory, touching neither `~/.claude` nor your status bar.
