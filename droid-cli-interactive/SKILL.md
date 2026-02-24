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
- `python3` available (for hook scripts)

## Model Families

When the user says "use Droid with Gemini/Codex/Claude/etc." (without specifying a version), resolve to the **best available model** in that family. Always use **max reasoning effort**.

| Family | Trigger words | Best model | Position | Cost | Max Reasoning |
|--------|--------------|------------|----------|------|---------------|
| **Gemini** (default) | "gemini", "google" | Gemini 3.1 Pro | 14 | 0.8x | high |
| **Codex** | "codex", "gpt", "openai" | GPT-5.3-Codex | 6 | 0.7x | xhigh |
| **Claude** | "claude", "opus", "anthropic" | Opus 4.6 | 10 | 2x | max |
| **Sonnet** | "sonnet" | Sonnet 4.6 | 8 | 1.2x | max |
| **Droid** | "droid", "glm", "droid core" | Droid Core (GLM-5) | 17 | 0.4x | high |

**AVOID**: Opus 4.6 Fast Mode (12x credit cost) - never select this unless user explicitly says "fast mode".

If user says just "run droid" / "launch droid" with no model preference → use **Gemini** family (default).
If user says a specific model version (e.g., "GPT-5.2-Codex") → use that exact model, not the family best.
If a newer/better model appears in a family in future Droid updates → prefer the newest highest-tier model in that family.

## Quick Start (Default Config)

**Defaults**: **Gemini** family (Gemini 3.1 Pro), **max reasoning** (high), `Auto (Off)` autonomy.

**IMPORTANT**: Always select the highest available reasoning effort for the chosen model: `max` for Claude, `xhigh` for GPT, `high` for Gemini/others.

**All available models** (with credit cost and selector position):

| # | Name | Cost | Max Reasoning |
|---|------|------|---------------|
| 1 | GPT-5.1 | 0.5x | xhigh |
| 2 | GPT-5.1-Codex | 0.5x | xhigh |
| 3 | GPT-5.1-Codex-Max | 0.5x | xhigh |
| 4 | GPT-5.2 | 0.7x | xhigh |
| 5 | GPT-5.2-Codex | 0.7x | xhigh |
| 6 | **GPT-5.3-Codex** | 0.7x | xhigh |
| 7 | Sonnet 4.5 | 1.2x | max |
| 8 | **Sonnet 4.6** | 1.2x | max |
| 9 | Opus 4.5 | 2x | max |
| 10 | **Opus 4.6** | 2x | max |
| 11 | Opus 4.6 Fast Mode | **12x** | max |
| 12 | Haiku 4.5 | 0.4x | high |
| 13 | Gemini 3 Pro | 0.8x | high |
| 14 | **Gemini 3.1 Pro** | 0.8x | high |
| 15 | Gemini 3 Flash | 0.2x | high |
| 16 | Droid Core (GLM-4.7) | 0.25x | high |
| 17 | **Droid Core (GLM-5)** | 0.4x | high |
| 18 | Droid Core (Kimi K2.5) | 0.25x | high |
| 19 | Droid Core (MiniMax M2.5) | 0.12x | high |

**Bold** = family best (what gets selected when user says the family name).

```bash
# Resolve the skill's scripts directory (needed for event-driven detection)
# The skill directory is either in the repo or symlinked from ~/.claude/skills/
DROID_SKILL_DIR="$(dirname "$(readlink -f "$(echo ~/.claude/skills/droid-cli-interactive/SKILL.md)" 2>/dev/null || echo ~/.claude/skills/droid-cli-interactive/SKILL.md)")"
DROID_SCRIPTS="$DROID_SKILL_DIR/scripts"

# 1. Install hooks (one-time, idempotent - safe to run every time)
"$DROID_SCRIPTS/droid-install-hooks.sh"

# 2. Setup tmux window (run each line separately)
tmux has-session -t tmux-cli 2>/dev/null || tmux new-session -d -s tmux-cli
DROID_WIN="droid-$(head -c4 /dev/urandom | xxd -p)"
DROID_PANE=$(tmux new-window -t tmux-cli -n "$DROID_WIN" -d -P -F '#{session_name}:#{window_name}.#{pane_index}' zsh)
DROID_PANE_ID=$(tmux display-message -t $DROID_PANE -p '#{pane_id}')
echo "PANE: $DROID_PANE  PANE_ID: $DROID_PANE_ID"

# 3. Start Droid
tmux-cli send "cd \"$(pwd)\" && droid" --pane=$DROID_PANE && \
tmux-cli wait_idle --pane=$DROID_PANE --idle-time=30.0

# 4. Verify launch (MANDATORY)
tmux-cli capture --pane=$DROID_PANE
# Check output contains Droid ASCII banner and model indicator at bottom
# Only proceed if Droid is confirmed running

# 5. Switch to target model family (see "Model Override" section)
#    Default family = Gemini → Gemini 3.1 Pro (position 14)
#    Droid launches on Gemini 3 Pro (position 13), so press Down 1 time
#    Then set max reasoning (see Model Override for full flow)
#    Skip this step ONLY if user explicitly wants Gemini 3 Pro (not 3.1)

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

## Event-Driven Detection

Instead of fixed idle-time polling, this skill uses Droid hooks + `tmux wait-for` for instant response detection with graceful fallback.

### How It Works

1. **Hook installation** (step 1): `droid-install-hooks.sh` adds Stop/SubagentStop/Notification hooks to `~/.factory/settings.json`. Idempotent - safe to run repeatedly.
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
| `scripts/droid-install-hooks.sh` | One-time idempotent hook installation |
| `scripts/droid-hook-signal.sh` | Hook dispatcher (called by Droid) |
| `scripts/droid-wait-event.sh` | Blocking waiter with timeout |

### Timeout Configuration

The default timeout for `droid-wait-event.sh` is 300s (5 min). For long tasks, increase it:
```bash
"$DROID_SCRIPTS/droid-wait-event.sh" "$DROID_PANE_ID" 600  # 10 min timeout
```

If the event-driven wait times out, the fallback `wait_idle` uses a shorter idle-time (30s default, 60s for security audits).

## Model Override

Use `/model` after Droid launches to switch to the target model. **Always required** - even for the default Gemini family, you must switch from Gemini 3 Pro (Droid's launch default at position 13) to Gemini 3.1 Pro (best-in-family at position 14).

### Navigation from launch position (Gemini 3 Pro, position 13)

| Target family | Target model | Arrows from pos 13 | Reasoning Down presses |
|--------------|-------------|---------------------|----------------------|
| **Gemini** (default) | Gemini 3.1 Pro (14) | Down x1 | 4 (to reach "high") |
| **Codex** | GPT-5.3-Codex (6) | Up x7 | 4 (to reach "xhigh") |
| **Claude** | Opus 4.6 (10) | Up x3 | 4 (to reach "max") |
| **Sonnet** | Sonnet 4.6 (8) | Up x5 | 4 (to reach "max") |
| **Droid** | GLM-5 (17) | Down x4 | 4 (to reach "high") |

**NOTE**: If you already switched models earlier in this session, the cursor starts at the **current model's position**, not position 13. Capture the pane first to see what model is active, then recalculate arrows.

```bash
# After step 4 (verify launch), switch to target model:

# 1. Open model selector
tmux-cli send "/model" --pane=$DROID_PANE && sleep 2

# 2. Navigate to target model (example: Gemini family → Down x1 from pos 13)
#    Replace arrow direction and count based on table above
tmux send-keys -t $DROID_PANE Down && sleep 0.5

# 3. Press Enter to confirm model selection
tmux send-keys -t $DROID_PANE Enter && sleep 2

# 4. A reasoning effort selector appears (Disabled/Low/Medium/High/Max or /Xhigh)
#    ALWAYS navigate to the LAST option (max reasoning for the model)
tmux send-keys -t $DROID_PANE Down Down Down Down && sleep 0.3 && \
tmux send-keys -t $DROID_PANE Enter && sleep 2

# 5. Capture to verify model changed (MANDATORY)
tmux-cli capture --pane=$DROID_PANE
# Check bottom status bar shows correct model + reasoning
# e.g., "Gemini 3.1 Pro (High)", "GPT-5.3-Codex (Xhigh)", "Opus 4.6 (Max)"
# If wrong model, repeat /model flow
```

**WARNING**: The model list order may change across Droid updates. After navigating, **always capture the pane and verify** the correct model name is shown in the status bar before sending prompts. If the wrong model was selected, use `/model` again to fix it.

**NEVER select Opus 4.6 Fast Mode (12x cost)** unless the user explicitly requests "fast mode".

## Task Presets

| Task | Family | Model | Reasoning | Autonomy | Wait Timeout |
|------|--------|-------|-----------|----------|--------------|
| Code review | Gemini | Gemini 3.1 Pro | high | Off | 300s |
| Security audit | Gemini | Gemini 3.1 Pro | high | Off | 600s |
| Refactoring (analyze) | Gemini | Gemini 3.1 Pro | high | Off | 300s |
| Refactoring (apply) | Gemini | Gemini 3.1 Pro | high | Low/Medium | 300s |
| Full access | Claude | Opus 4.6 | max | High | 600s |

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
| excl. mark | Toggle Bash mode |

## Configuration Overrides

Only ask user for config (via `AskUserQuestion`) when:
- User explicitly requests different settings (model, autonomy)
- Task requires autonomy above Off
- Multiple reasonable approaches exist

Otherwise, use defaults and proceed immediately.

## Error Handling

- **CRITICAL: After starting Droid, ALWAYS capture the pane output and verify Droid launched successfully** before sending any prompts. Look for the ASCII banner and model indicator (e.g., `Gemini 3 Pro (High)`) at the bottom of the screen.
- **Event-driven wait fails**: Falls back to `wait_idle` automatically via `||` operator. No manual intervention needed.
- **Droid exits unexpectedly**: capture output to see error, restart from step 2
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

- Droid interactive mode has NO `--model` CLI flag; use `/model` slash command after launch to switch
- **Always switch model after launch** - even for default Gemini family (3 Pro → 3.1 Pro)
- When user says "use Droid with X" - resolve X to a family, pick the best model, navigate to it
- For non-interactive use, prefer `droid exec -m MODEL_ID` with `--auto` level
- Never use `tmux-cli launch` - use `tmux new-window -t tmux-cli -n <unique-name>` for isolation
- Summarize Droid findings for user after capturing output
- Hook state files are in `/tmp/droid-event-state/` and cleaned up automatically
