---
name: droid-cli-interactive
description: Run interactive Droid CLI sessions using tmux-cli for code review, audit, refactoring, and multi-turn conversations with Factory's Droid agent. Use when the user asks to run droid, launch droid, or use Factory's AI agent.
---

# Droid Interactive Skill

Run Droid CLI sessions via tmux-cli for code review, security audits, refactoring, and multi-turn conversations.

## Prerequisites

- `tmux` (v3+) and `tmux-cli` installed and on PATH
- Droid CLI (`droid`) installed and authenticated with Factory API key (`FACTORY_API_KEY`)
- `zsh` shell available
- `python3` available (for hook and model scripts)

## Model Families

When the user says "use Droid with Gemini/Codex/Claude/etc." (without specifying a version), resolve to the **best available model** in that family. Always use **max reasoning effort**.

| Family | Trigger words | Model ID | Display name | Cost | Max Reasoning |
|--------|--------------|----------|--------------|------|---------------|
| **Gemini** (default) | "gemini", "google" | `gemini-3.1-pro-preview` | Gemini 3.1 Pro | 0.8x | high |
| **Codex** | "codex", "gpt", "openai" | `gpt-5.3-codex` | GPT-5.3-Codex | 0.7x | xhigh |
| **Claude** | "claude", "opus", "anthropic" | `claude-opus-4-6` | Opus 4.6 | 2x | max |
| **Sonnet** | "sonnet" | `claude-sonnet-4-6` | Sonnet 4.6 | 1.2x | max |
| **Droid** | "droid", "glm", "droid core" | `glm-5` | Droid Core (GLM-5) | 0.4x | high |

**AVOID**: Opus 4.6 Fast Mode (12x credit cost) - never select this unless user explicitly says "fast mode".

If user says just "run droid" / "launch droid" with no model preference, use **Gemini** family (default).
If user says a specific model version (e.g., "GPT-5.2-Codex"), use that exact model ID, not the family best.
If a newer/better model appears in a family in future Droid updates, prefer the newest highest-tier model.

## Quick Start

```bash
# Resolve the skill's scripts directory
DROID_SKILL_DIR="$(dirname "$(readlink -f "$(echo ~/.claude/skills/droid-cli-interactive/SKILL.md)" 2>/dev/null || echo ~/.claude/skills/droid-cli-interactive/SKILL.md)")"
DROID_SCRIPTS="$DROID_SKILL_DIR/scripts"

# 1. Set model BEFORE launch (Droid reads ~/.factory/settings.json at startup)
#    Use the Model ID and Max Reasoning from the Model Families table above
#    Default: Gemini family
"$DROID_SCRIPTS/droid-set-model.sh" "gemini-3.1-pro-preview" "high"

# 2. Install hooks (one-time, idempotent - safe to run every time)
"$DROID_SCRIPTS/droid-install-hooks.sh"

# 3. Setup tmux window
tmux has-session -t tmux-cli 2>/dev/null || tmux new-session -d -s tmux-cli
DROID_WIN="droid-$(head -c4 /dev/urandom | xxd -p)"
DROID_PANE=$(tmux new-window -t tmux-cli -n "$DROID_WIN" -d -P -F '#{session_name}:#{window_name}.#{pane_index}' zsh)
DROID_PANE_ID=$(tmux display-message -t $DROID_PANE -p '#{pane_id}')
echo "PANE: $DROID_PANE  PANE_ID: $DROID_PANE_ID"

# 4. Start Droid (it will use the model set in step 1)
tmux-cli send "cd \"$(pwd)\" && droid" --pane=$DROID_PANE && \
tmux-cli wait_idle --pane=$DROID_PANE --idle-time=30.0

# 5. Verify launch (MANDATORY)
tmux-cli capture --pane=$DROID_PANE
# Check output contains Droid ASCII banner
# Check bottom status bar shows correct model (e.g., "Gemini 3.1 Pro (High)")
# Only proceed if Droid is confirmed running with the right model

# 6. Send prompt + wait for response + capture (repeat for each interaction)
tmux-cli send "<YOUR_PROMPT>" --pane=$DROID_PANE && \
("$DROID_SCRIPTS/droid-wait-event.sh" "$DROID_PANE_ID" 300 || \
 tmux-cli wait_idle --pane=$DROID_PANE --idle-time=30.0) && \
tmux-cli capture --pane=$DROID_PANE

# 7. End session (MANDATORY - always run when done)
tmux send-keys -t $DROID_PANE C-c && sleep 0.3 && tmux send-keys -t $DROID_PANE C-c && \
sleep 2 && tmux kill-window -t "tmux-cli:$DROID_WIN"
```

**IMPORTANT: You MUST always run step 7 to close the tmux window when the Droid session is finished.** Never leave the window open after the task is complete.

**EXIT METHOD**: Droid uses **double Ctrl+C** (rapid, <1s apart) to exit. NOT `/exit`.

**WHY WINDOWS INSTEAD OF PANES**: Each Droid session runs in its own dedicated tmux window with a unique name (e.g., `droid-a1b2c3d4`). This prevents a race condition where concurrent sessions break each other - pane indices shift when any pane closes, but window names are stable.

## Model Selection

**Models are set via `~/.factory/settings.json` BEFORE launching Droid.** Do NOT use `/model` slash command or arrow key navigation - that approach is fragile and error-prone.

```bash
# Set model before launching Droid (step 1 in Quick Start)
"$DROID_SCRIPTS/droid-set-model.sh" "<MODEL_ID>" "<REASONING>"
```

### Examples

```bash
# Gemini (default)
"$DROID_SCRIPTS/droid-set-model.sh" "gemini-3.1-pro-preview" "high"

# Codex
"$DROID_SCRIPTS/droid-set-model.sh" "gpt-5.3-codex" "xhigh"

# Claude
"$DROID_SCRIPTS/droid-set-model.sh" "claude-opus-4-6" "max"

# Sonnet
"$DROID_SCRIPTS/droid-set-model.sh" "claude-sonnet-4-6" "max"

# Droid Core
"$DROID_SCRIPTS/droid-set-model.sh" "glm-5" "high"
```

### All Available Model IDs

| Model ID | Display Name | Cost | Max Reasoning |
|----------|-------------|------|---------------|
| `gpt-5.1` | GPT-5.1 | 0.5x | xhigh |
| `gpt-5.1-codex` | GPT-5.1-Codex | 0.5x | xhigh |
| `gpt-5.1-codex-max` | GPT-5.1-Codex-Max | 0.5x | xhigh |
| `gpt-5.2` | GPT-5.2 | 0.7x | xhigh |
| `gpt-5.2-codex` | GPT-5.2-Codex | 0.7x | xhigh |
| `gpt-5.3-codex` | GPT-5.3-Codex | 0.7x | xhigh |
| `claude-sonnet-4-5` | Sonnet 4.5 | 1.2x | max |
| `claude-sonnet-4-6` | Sonnet 4.6 | 1.2x | max |
| `claude-opus-4-5` | Opus 4.5 | 2x | max |
| `claude-opus-4-6` | Opus 4.6 | 2x | max |
| `claude-haiku-4-5-20251001` | Haiku 4.5 | 0.4x | high |
| `gemini-3-pro-preview` | Gemini 3 Pro | 0.8x | high |
| `gemini-3.1-pro-preview` | Gemini 3.1 Pro | 0.8x | high |
| `gemini-3-flash-preview` | Gemini 3 Flash | 0.2x | high |
| `glm-4.7` | Droid Core (GLM-4.7) | 0.25x | high |
| `glm-5` | Droid Core (GLM-5) | 0.4x | high |
| `kimi-k2.5` | Droid Core (Kimi K2.5) | 0.25x | high |
| `minimax-m2.5` | Droid Core (MiniMax M2.5) | 0.12x | high |

**NOTE**: When running multiple Droid instances with different models, call `droid-set-model.sh` before each `droid` launch. The script modifies `~/.factory/settings.json` which Droid reads at startup. Launch Droid immediately after setting the model.

## Event-Driven Detection

Instead of fixed idle-time polling, this skill uses Droid hooks + `tmux wait-for` for instant response detection with graceful fallback.

### How It Works

1. **Hook installation** (step 2): `droid-install-hooks.sh` adds Stop/SubagentStop/Notification hooks to `~/.factory/settings.json`. Idempotent - safe to run repeatedly.
2. **Nonce-per-wait**: Each `droid-wait-event.sh` call creates a unique nonce written to `/tmp/droid-event-state/<pane_id>/nonce`. This avoids `tmux wait-for` parity issues (repeated signals on the same channel toggle state rather than accumulate).
3. **Hook fires**: When Droid finishes a response, the hook script (`droid-hook-signal.sh`) walks PID ancestry to discover which tmux pane it belongs to, reads the nonce, and signals `tmux wait-for -S "droid-<nonce>"`.
4. **Fallback**: If the hook doesn't fire within timeout (e.g., hooks not installed, PID discovery fails), `droid-wait-event.sh` exits non-zero and the `||` triggers `tmux-cli wait_idle` as fallback.

### Concurrency Safety

- **Unique nonce per wait**: Each concurrent instance uses its own channel name - no cross-talk.
- **PID ancestry discovery**: Each hook process discovers its own tmux pane independently - no shared state.
- **One-time hook install**: No per-session settings.json modification - no race conditions on the config file.
- **State isolation**: Each pane has its own state directory at `/tmp/droid-event-state/<pane_id>/`.

### Scripts Reference

| Script | Purpose |
|--------|---------|
| `scripts/droid-set-model.sh` | Set model and reasoning in settings.json before launch |
| `scripts/droid-install-hooks.sh` | One-time idempotent hook installation |
| `scripts/droid-hook-signal.sh` | Hook dispatcher (called by Droid on Stop/Notification) |
| `scripts/droid-wait-event.sh` | Blocking waiter with timeout |

### Timeout Configuration

The default timeout for `droid-wait-event.sh` is 300s (5 min). For long tasks, increase it:
```bash
"$DROID_SCRIPTS/droid-wait-event.sh" "$DROID_PANE_ID" 600  # 10 min timeout
```

If the event-driven wait times out, the fallback `wait_idle` uses a shorter idle-time (30s default, 60s for security audits).

## Task Presets

| Task | Family | Model ID | Reasoning | Autonomy | Wait Timeout |
|------|--------|----------|-----------|----------|--------------|
| Code review | Gemini | `gemini-3.1-pro-preview` | high | Off | 300s |
| Security audit | Gemini | `gemini-3.1-pro-preview` | high | Off | 600s |
| Refactoring (analyze) | Gemini | `gemini-3.1-pro-preview` | high | Off | 300s |
| Refactoring (apply) | Gemini | `gemini-3.1-pro-preview` | high | Low/Medium | 300s |
| Full access | Claude | `claude-opus-4-6` | max | High | 600s |

**Permission required**: Ask user before using autonomy levels above Off.

Use the user's requested family if specified, otherwise default to Gemini for all tasks.

## Core Operations

### Send + Wait + Capture Pattern
Always chain these together:
```bash
tmux-cli send "<PROMPT>" --pane=$DROID_PANE && \
("$DROID_SCRIPTS/droid-wait-event.sh" "$DROID_PANE_ID" 300 || \
 tmux-cli wait_idle --pane=$DROID_PANE --idle-time=30.0) && \
tmux-cli capture --pane=$DROID_PANE
```

### Check Session Status
```bash
tmux list-panes -t tmux-cli -F '#{pane_id} #{pane_current_command}'
```

### Interrupt Long Task
```bash
tmux-cli interrupt --pane=$DROID_PANE
```

### Keyboard Shortcuts (reference)

| Shortcut | Action |
|----------|--------|
| `Ctrl+N` | Cycle models |
| `Tab` | Cycle reasoning level |
| `Shift+Tab` | Cycle modes (Auto/Spec/Mission) |
| `Ctrl+L` | Cycle autonomy (Off/Low/Medium/High) |
| `Ctrl+O` | Toggle detailed view |
| `Esc` | Cancel current action |
| `Ctrl+C` x2 | Exit Droid |
| `@` | Mention files |
| `/` | Commands menu |

## Error Handling

- **CRITICAL: After starting Droid, ALWAYS capture the pane output and verify Droid launched successfully** before sending any prompts. Look for the ASCII banner and model indicator (e.g., `Gemini 3.1 Pro (High)`) at the bottom of the screen.
- **Wrong model shown**: Re-run `droid-set-model.sh` with the correct model ID, exit Droid (double Ctrl+C), and relaunch.
- **Event-driven wait fails**: Falls back to `wait_idle` automatically via `||` operator. No manual intervention needed.
- **Droid exits unexpectedly**: capture output to see error, restart from step 3
- **Window closes**: check `tmux list-windows -t tmux-cli`, recreate window and update `DROID_WIN`/`DROID_PANE`/`DROID_PANE_ID`
- **wait_idle hangs/times out**: increase idle-time (+15s), or use `tmux-cli interrupt --pane=$DROID_PANE` then retry
- **Auth issues**: user must set `FACTORY_API_KEY` environment variable
- **Hook installation issues**: Run `"$DROID_SCRIPTS/droid-install-hooks.sh"` manually. Check `~/.factory/settings.json` for hook entries. Backup is at `~/.factory/settings.json.pre-hooks-backup`.

## Cleanup (MANDATORY)

**You MUST close the Droid window when the session is complete.** Always run step 7 after all interactions are done:
```bash
tmux send-keys -t $DROID_PANE C-c && sleep 0.3 && tmux send-keys -t $DROID_PANE C-c && \
sleep 2 && tmux kill-window -t "tmux-cli:$DROID_WIN"
```

If the window is already dead (Droid crashed or exited on its own), still ensure cleanup:
```bash
tmux kill-window -t "tmux-cli:$DROID_WIN" 2>/dev/null
```

**Never leave a Droid window running after the task is finished.**

## Notes

- Droid interactive mode has NO `--model` CLI flag; model is set via `~/.factory/settings.json` before launch
- **Always call `droid-set-model.sh` before launching Droid** to ensure the correct model
- When user says "use Droid with X" - resolve X to a family, get the Model ID, call `droid-set-model.sh`
- For non-interactive use, prefer `droid exec -m MODEL_ID` with `--auto` level
- Never use `tmux-cli launch` - use `tmux new-window -t tmux-cli -n <unique-name>` for isolation
- Summarize Droid findings for user after capturing output
- Hook state files are in `/tmp/droid-event-state/` and cleaned up automatically
