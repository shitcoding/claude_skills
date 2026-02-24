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

## Quick Start (Default Config)

**Defaults**: `gemini-3-pro-preview` model, **max available** reasoning (`high` for Gemini), `Auto (Off)` autonomy, `30s` idle-time.

**IMPORTANT**: Always select the highest available reasoning effort for the chosen model: `max` for Claude, `xhigh` for GPT, `high` for Gemini/others. See the table below for each model's max level.

**Available models** (pass model ID):

| Model ID | Name | Reasoning Levels | Default |
|----------|------|-------------------|---------|
| `gemini-3-pro-preview` | Gemini 3 Pro | none, low, medium, high | high |
| `gemini-3.1-pro-preview` | Gemini 3.1 Pro | low, medium, high | high |
| `gemini-3-flash-preview` | Gemini 3 Flash | minimal, low, medium, high | high |
| `claude-opus-4-6` | Claude Opus 4.6 | off, low, medium, high, max | high |
| `claude-sonnet-4-6` | Claude Sonnet 4.6 | off, low, medium, high, max | high |
| `claude-haiku-4-5-20251001` | Claude Haiku 4.5 | off, low, medium, high | off |
| `gpt-5.3-codex` | GPT-5.3-Codex | none, low, medium, high, xhigh | medium |
| `gpt-5.2-codex` | GPT-5.2-Codex | none, low, medium, high, xhigh | medium |

```bash
# 1. Setup (run each line separately)
tmux has-session -t tmux-cli 2>/dev/null || tmux new-session -d -s tmux-cli
DROID_WIN="droid-$(head -c4 /dev/urandom | xxd -p)"
DROID_PANE=$(tmux new-window -t tmux-cli -n "$DROID_WIN" -d -P -F '#{session_name}:#{window_name}.#{pane_index}' zsh)
echo "PANE: $DROID_PANE"

# 2. Start Droid (with optional model override - see "Model Override" section)
tmux-cli send "cd \"$(pwd)\" && droid" --pane=$DROID_PANE && \
tmux-cli wait_idle --pane=$DROID_PANE --idle-time=30.0

# 3. Verify launch (MANDATORY)
tmux-cli capture --pane=$DROID_PANE
# Check output contains Droid ASCII banner and model indicator at bottom
# Only proceed if Droid is confirmed running

# 4. (Optional) Set max reasoning if model supports higher than current
#    Use Tab to cycle reasoning. Gemini 3 Pro max is "high" (already default).
#    For other models, cycle Tab until max is reached, then capture to verify.

# 5. Send prompt + capture (repeat for each interaction)
tmux-cli send "<YOUR_PROMPT>" --pane=$DROID_PANE && \
tmux-cli wait_idle --pane=$DROID_PANE --idle-time=30.0 && \
tmux-cli capture --pane=$DROID_PANE

# 6. End session (MANDATORY - always run when done)
tmux send-keys -t $DROID_PANE C-c && sleep 0.3 && tmux send-keys -t $DROID_PANE C-c && \
sleep 2 && tmux kill-window -t "tmux-cli:$DROID_WIN"
```

**IMPORTANT: You MUST always run step 6 to close the tmux window when the Droid session is finished.** Never leave the window open after the task is complete.

**EXIT METHOD**: Droid uses **double Ctrl+C** (rapid, <1s apart) to exit. NOT `/exit`.

**WHY WINDOWS INSTEAD OF PANES**: Each Droid session runs in its own dedicated tmux window with a unique name (e.g., `droid-a1b2c3d4`). This prevents a race condition where concurrent sessions break each other - pane indices shift when any pane closes, but window names are stable.

## Model Override

If user requests a non-default model, use the `/model` slash command after Droid launches. This opens an interactive model selector.

**Model selector order** (top to bottom):
1. GPT-5.1
2. GPT-5.1-Codex
3. GPT-5.1-Codex-Max
4. GPT-5.2
5. GPT-5.2-Codex
6. GPT-5.3-Codex
7. Sonnet 4.5
8. Sonnet 4.6
9. Opus 4.5
10. Opus 4.6
11. Opus 4.6 Fast Mode
12. Haiku 4.5
13. **Gemini 3 Pro [default/current]**
14. Gemini 3.1 Pro
15. Gemini 3 Flash
16. Droid Core (GLM-4.7)
17. Droid Core (GLM-5)
18. Droid Core (Kimi K2.5)
19. Droid Core (MiniMax M2.5)

```bash
# After step 3 (verify launch), switch model:
# 1. Open model selector
tmux-cli send "/model" --pane=$DROID_PANE && sleep 2

# 2. Navigate to desired model using arrow keys
#    Cursor starts on current model (Gemini 3 Pro, position 13)
#    Use Up arrow to go higher in list, Down to go lower
#    Example: to select Opus 4.6 (position 10), press Up 3 times
tmux send-keys -t $DROID_PANE Up Up Up && sleep 0.5

# 3. Press Enter to confirm model selection
tmux send-keys -t $DROID_PANE Enter && sleep 2

# 4. A reasoning effort selector appears next (Disabled/Low/Medium/High/Max)
#    ALWAYS select the MAX available reasoning for the model
#    Navigate with Down to reach the bottom option (max/xhigh/high), then Enter
tmux send-keys -t $DROID_PANE Down Down Down Down && sleep 0.3 && \
tmux send-keys -t $DROID_PANE Enter && sleep 2

# 5. Capture to verify model changed
tmux-cli capture --pane=$DROID_PANE
# Check bottom status bar shows new model name (e.g., "Opus 4.6 (High)")
```

**Navigation**: Count positions from current model to target. Use `Up` to go toward top of list, `Down` toward bottom.

**WARNING**: The model list order may change across Droid updates. After navigating, **always capture the pane and verify** the correct model name is shown in the status bar before sending prompts. If the wrong model was selected, use `/model` again to fix it.

If user doesn't specify a model, use the default (`gemini-3-pro-preview`) and skip model override entirely.

## Task Presets

| Task | Model | Reasoning | Autonomy | Idle Time |
|------|-------|-----------|----------|-----------|
| Code review | `gemini-3-pro-preview` | `high` (max avail) | Off | 30s |
| Security audit | `gemini-3-pro-preview` | `high` (max avail) | Off | 60s |
| Refactoring (analyze) | `gemini-3-pro-preview` | `high` (max avail) | Off | 30s |
| Refactoring (apply) | `gemini-3-pro-preview` | `high` (max avail) | Low/Medium | 30s |
| Full access | `claude-opus-4-6` | `max` | High | 60s |

**Permission required**: Ask user before using autonomy levels above Off.

## Core Operations

### Send + Capture Pattern
Always chain these together:
```bash
tmux-cli send "<PROMPT>" --pane=$DROID_PANE && \
tmux-cli wait_idle --pane=$DROID_PANE --idle-time=30.0 && \
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
| `!` | Toggle Bash mode |

## Configuration Overrides

Only ask user for config (via `AskUserQuestion`) when:
- User explicitly requests different settings (model, autonomy)
- Task requires autonomy above Off
- Multiple reasonable approaches exist

Otherwise, use defaults and proceed immediately.

## Error Handling

- **CRITICAL: After starting Droid, ALWAYS capture the pane output and verify Droid launched successfully** before sending any prompts. Look for the ASCII banner and model indicator (e.g., `Gemini 3 Pro (High)`) at the bottom of the screen.
- **Droid exits unexpectedly**: capture output to see error, restart from step 1
- **Window closes**: check `tmux list-windows -t tmux-cli`, recreate window and update `DROID_WIN`/`DROID_PANE`
- **wait_idle hangs/times out**: increase idle-time (+15s), or use `tmux-cli interrupt --pane=$DROID_PANE` then retry
- **Auth issues**: user must set `FACTORY_API_KEY` environment variable

## Cleanup (MANDATORY)

**You MUST close the Droid window when the session is complete.** Always run step 6 after all interactions are done:
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
- For non-interactive use, prefer `droid exec -m MODEL_ID` with `--auto` level
- Never use `tmux-cli launch` - use `tmux new-window -t tmux-cli -n <unique-name>` for isolation
- Default idle-time is 30s; use 60s for security audits or complex tasks
- Summarize Droid findings for user after capturing output
