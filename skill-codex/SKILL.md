---
name: codex-cli-interactive
description: Run interactive Codex CLI sessions using tmux-cli for code review, audit, refactoring, and multi-turn conversations with OpenAI Codex
---

# Codex Interactive Skill

Run Codex CLI sessions via tmux-cli for code review, security audits, refactoring, and multi-turn conversations.

## Prerequisites

- `tmux` (v3+) and `tmux-cli` installed and on PATH
- Codex CLI (`codex`) installed and authenticated with OpenAI credentials
- `zsh` shell available

## Quick Start (Default Config)

**Defaults**: `gpt-5.2-codex`, `high` reasoning, `read-only` sandbox, `30s` idle-time.

```bash
# 1. Setup (run each line separately)
tmux has-session -t tmux-cli 2>/dev/null || tmux new-session -d -s tmux-cli
CODEX_PANE=$(tmux split-window -t tmux-cli -h -P -F '#{session_name}:#{window_index}.#{pane_index}' zsh)
echo "PANE: $CODEX_PANE"

# 2. Start Codex
tmux-cli send "cd $(pwd) && codex -m gpt-5.2-codex -c model_reasoning_effort=\"high\" -s read-only" --pane=$CODEX_PANE && \
tmux-cli wait_idle --pane=$CODEX_PANE --idle-time=30.0

# 3. Send prompt + capture (repeat for each interaction)
tmux-cli send "<YOUR_PROMPT>" --pane=$CODEX_PANE && \
tmux-cli wait_idle --pane=$CODEX_PANE --idle-time=30.0 && \
tmux-cli capture --pane=$CODEX_PANE

# 4. End session
tmux-cli send "/exit" --pane=$CODEX_PANE && \
tmux-cli wait_idle --pane=$CODEX_PANE --idle-time=5.0 && \
tmux kill-pane -t $CODEX_PANE
```

## Task Presets

Use these configurations based on task type:

| Task | Model | Reasoning | Sandbox | Idle Time |
|------|-------|-----------|---------|-----------|
| Code review | `gpt-5.2-codex` | `high` | `read-only` | 30s |
| Security audit | `gpt-5.2-codex` | `high` | `read-only` | 60s |
| Refactoring (analyze) | `gpt-5.2-codex` | `high` | `read-only` | 30s |
| Refactoring (apply) | `gpt-5.2-codex` | `medium` | `workspace-write` | 30s |
| Full access | `gpt-5` | `high` | `danger-full-access` | 60s |

**Permission required**: Ask user before using `workspace-write` or `danger-full-access` sandbox modes.

## Core Operations

### Send + Capture Pattern
Always chain these together:
```bash
tmux-cli send "<PROMPT>" --pane=$CODEX_PANE && \
tmux-cli wait_idle --pane=$CODEX_PANE --idle-time=30.0 && \
tmux-cli capture --pane=$CODEX_PANE
```

### Check Session Status
```bash
tmux list-panes -t tmux-cli -F '#{pane_id} #{pane_current_command}'
```

### Interrupt Long Task
```bash
tmux-cli interrupt --pane=$CODEX_PANE
```

## Configuration Overrides

Only ask user for config (via `AskUserQuestion`) when:
- User explicitly requests different settings
- Task requires write access (`workspace-write` or `danger-full-access`)
- Multiple reasonable approaches exist

Otherwise, use defaults and proceed immediately.

## Error Handling

- **Codex exits unexpectedly**: capture output to see error, restart from step 1
- **Pane closes**: check `tmux list-panes -t tmux-cli`, recreate pane and update `CODEX_PANE`
- **wait_idle hangs/times out**: increase idle-time (+15s), or use `tmux-cli interrupt --pane=$CODEX_PANE` then retry
- **Auth issues**: user must fix credentials outside session

## Notes

- Use short flags: `-m` (model), `-c` (config), `-s` (sandbox)
- Never use `tmux-cli launch` - use `tmux split-window -t tmux-cli`
- Default idle-time is 30s; use 60s for security audits or complex tasks
- Summarize Codex findings for user after capturing output
- Clean up panes when done to avoid resource leaks
