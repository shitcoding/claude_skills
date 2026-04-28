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
- `python3` available (for hook and config scripts)

## Quick Start

**Defaults**: `gpt-5.5`, `xhigh` reasoning, `read-only` sandbox.

Valid `model_reasoning_effort` values: `none`, `minimal`, `low`, `medium`, `high`, `xhigh`.

```bash
# Resolve the skill's scripts directory
# Try: symlink at ~/.claude/skills, then check common project locations
CODEX_SKILL_DIR=""
for candidate in \
    "$(dirname "$(readlink -f ~/.claude/skills/skill-codex/SKILL.md 2>/dev/null)" 2>/dev/null)" \
    "$(find ~/.claude/skills -maxdepth 3 -name 'codex-hook-signal.sh' -print -quit 2>/dev/null | xargs dirname 2>/dev/null | xargs dirname 2>/dev/null)"; do
    [ -d "$candidate/scripts" ] && CODEX_SKILL_DIR="$candidate" && break
done
# Fallback: if this skill is loaded, its own directory is the skill dir
[ -z "$CODEX_SKILL_DIR" ] && echo "ERROR: Cannot find skill-codex scripts directory" && exit 1
CODEX_SCRIPTS="$CODEX_SKILL_DIR/scripts"

# 1. Update Codex CLI (avoids "update available" prompt blocking TUI)
"$CODEX_SCRIPTS/codex-update.sh"

# 2. Install hooks (one-time, idempotent - safe to run every time)
"$CODEX_SCRIPTS/codex-install-hooks.sh"

# 3. Setup tmux window
tmux has-session -t tmux-cli 2>/dev/null || tmux new-session -d -s tmux-cli
CODEX_WIN="codex-$(head -c4 /dev/urandom | xxd -p)"
CODEX_PANE=$(tmux new-window -t tmux-cli -n "$CODEX_WIN" -d -P -F '#{session_name}:#{window_name}.#{pane_index}' zsh)
CODEX_PANE_ID=$(tmux display-message -t $CODEX_PANE -p '#{pane_id}')
echo "PANE: $CODEX_PANE  PANE_ID: $CODEX_PANE_ID"

# 4. Start Codex
tmux-cli send "cd \"$(printf '%q' "$(pwd)")\" && codex -m gpt-5.5 -c model_reasoning_effort=\"xhigh\" -s read-only" --pane=$CODEX_PANE && \
tmux-cli wait_idle --pane=$CODEX_PANE --idle-time=30.0

# 5. Verify launch (MANDATORY)
tmux-cli capture --pane=$CODEX_PANE
# Check output contains Codex banner with model indicator (e.g., "gpt-5.5 xhigh")
# If "update available" prompt appears: see Error Handling section
# Only proceed if Codex is confirmed running

# 6. Send prompt + wait for response + capture (repeat for each interaction)
#    IMPORTANT: Arm waiter BEFORE sending prompt to avoid race condition
#    (fast Codex response could fire Stop hook before nonce is written)
"$CODEX_SCRIPTS/codex-wait-event.sh" "$CODEX_PANE_ID" 300 any &
WAITER_PID=$!
# Wait until nonce is written (readiness check, not just a sleep)
NONCE_PATH="${TMPDIR:-/tmp}/codex-event-state/${CODEX_PANE_ID#%}/nonce"
for i in $(seq 1 10); do [ -f "$NONCE_PATH" ] && break; sleep 0.1; done
tmux-cli send "<YOUR_PROMPT>" --pane=$CODEX_PANE
wait $WAITER_PID
WAIT_EXIT=$?
if [ "$WAIT_EXIT" -eq 0 ]; then
    # Turn complete - capture output
    tmux-cli capture --pane=$CODEX_PANE
elif [ "$WAIT_EXIT" -eq 2 ]; then
    # Approval needed - capture to see what Codex is asking
    tmux-cli capture --pane=$CODEX_PANE
    # Read the approval prompt, decide to approve or deny
    # Then arm a new waiter BEFORE responding and wait for turn to complete
elif [ "$WAIT_EXIT" -eq 124 ]; then
    # Timeout - fall back to wait_idle
    tmux-cli wait_idle --pane=$CODEX_PANE --idle-time=30.0
    tmux-cli capture --pane=$CODEX_PANE
fi

# 7. End session (MANDATORY - always run when done)
#    Try graceful exit first, then force-kill to guarantee cleanup
tmux-cli send "/exit" --pane=$CODEX_PANE && \
tmux-cli wait_idle --pane=$CODEX_PANE --idle-time=5.0 || true
tmux kill-window -t "tmux-cli:$CODEX_WIN" 2>/dev/null || true
```

**IMPORTANT: You MUST always run step 7 to close the tmux window when the Codex session is finished.** Never leave the window open after the task is complete.

**WHY WINDOWS INSTEAD OF PANES**: Each Codex session runs in its own dedicated tmux window with a unique name (e.g., `codex-a1b2c3d4`). This prevents a race condition where concurrent sessions break each other -- pane indices shift when any pane closes, but window names are stable.

## Event-Driven Detection

Instead of fixed idle-time polling, this skill uses Codex hooks + `tmux wait-for` for instant response detection with graceful fallback.

### How It Works

1. **Hook installation** (step 2): `codex-install-hooks.sh` appends Stop and PermissionRequest hooks to `~/.codex/hooks.json` and enables the `codex_hooks` feature flag. Idempotent -- safe to run repeatedly. Never overwrites existing user hooks.

2. **Nonce-per-wait**: Each `codex-wait-event.sh` call creates a unique 16-char hex nonce written to `${TMPDIR:-/tmp}/codex-event-state/<pane_id>/nonce`. This avoids `tmux wait-for` parity issues (repeated signals on the same channel toggle state rather than accumulate).

3. **Dual-channel wait**: In `any` mode, the wait script listens on both `codex-stop-<nonce>` and `codex-approval-<nonce>` channels simultaneously. First to fire wins.

4. **Hook fires**: When Codex finishes a turn (Stop) or needs approval (PermissionRequest), the hook script (`codex-hook-signal.sh`) walks PID ancestry to discover its tmux pane, reads the nonce, and signals the appropriate channel.

5. **Arm-before-send**: The waiter MUST be started in the background BEFORE sending the prompt. This ensures the nonce file exists before Codex can fire a hook. A fast Codex response firing Stop before the nonce is written would silently miss the signal.

6. **Distinct exit codes**: 0 = turn complete, 2 = approval needed, 124 = timeout. The skill branches on the exit code.

7. **Fallback**: If hooks don't fire within timeout (e.g., hooks not installed, PID discovery fails), exit code 124 triggers `wait_idle` as fallback.

### Approval Handling Flow

When `codex-wait-event.sh` returns exit 2 (approval needed):
1. Capture the pane to see what Codex is asking permission for
2. Read the approval prompt text
3. Arm a NEW waiter BEFORE responding (same arm-before-send principle):
   ```bash
   "$CODEX_SCRIPTS/codex-wait-event.sh" "$CODEX_PANE_ID" 300 any &
   WAITER_PID=$!
   sleep 0.5
   ```
4. Send approval or denial:
   - To approve: send `y` then Enter to the pane
   - To deny: send Escape to the pane
5. Wait for the turn to complete: `wait $WAITER_PID`

### Scripts Reference

| Script | Purpose |
|--------|---------|
| `scripts/codex-update.sh` | Update Codex CLI before launch to avoid update prompts |
| `scripts/codex-install-hooks.sh` | One-time idempotent hook installation (append-only) |
| `scripts/codex-hook-signal.sh` | Hook dispatcher (called by Codex on Stop/PermissionRequest) |
| `scripts/codex-wait-event.sh` | Blocking dual-channel waiter with distinct exit codes |

### Concurrency Safety

- **Unique nonce per wait**: Each concurrent instance uses its own channel names -- no cross-talk
- **PID ancestry discovery**: Each hook process discovers its own tmux pane independently
- **One-time hook install**: No per-session hooks.json modification -- no race conditions
- **State isolation**: Each pane has its own state directory at `${TMPDIR:-/tmp}/codex-event-state/<pane_id>/`
- **Restrictive permissions**: State dirs created with mode 700
- **Atomic nonce writes**: Write to temp file then `mv` to prevent partial reads

### Timeout Configuration

The default timeout for `codex-wait-event.sh` is 300s (5 min). For long tasks, increase it:
```bash
"$CODEX_SCRIPTS/codex-wait-event.sh" "$CODEX_PANE_ID" 600 any  # 10 min timeout
```

If the event-driven wait times out, the fallback `wait_idle` uses a 30s idle-time.

### Fallback: Detecting Mid-Turn User Input Requests

Codex's `request_user_input` prompts (clarifying questions, not tool approvals) do not yet have a hook event (open issue #12524). If the event-driven wait times out but Codex hasn't finished, check if it's asking for input:

```bash
content=$(tmux capture-pane -p -t "$CODEX_PANE" -S -25)
# Two-tier check: question header AND answer chips both present (prevents false positives)
if echo "$content" | grep -qE 'Would you like to (run|make)|Allow Codex to|Approve app tool call|Do you trust|Enable full access'; then
    if echo "$content" | grep -qE 'Yes, proceed|Yes, just this once|Yes, continue|Run the tool and continue|No, and tell Codex'; then
        echo "WAITING_APPROVAL"
    fi
elif echo "$content" | grep -qE 'esc to interrupt|Thinking|Working'; then
    echo "THINKING"
elif echo "$content" | grep -qE '^[[:space:]]*❯[[:space:]]*$'; then
    echo "IDLE"
fi
```

## Task Presets

Use these configurations based on task type:

| Task | Model | Reasoning | Sandbox | Wait Timeout |
|------|-------|-----------|---------|--------------|
| Code review | `gpt-5.5` | `xhigh` | `read-only` | 300s |
| Security audit | `gpt-5.5` | `xhigh` | `read-only` | 600s |
| Refactoring (analyze) | `gpt-5.5` | `xhigh` | `read-only` | 300s |
| Refactoring (apply) | `gpt-5.5` | `high` | `workspace-write` | 300s |
| Full access | `gpt-5.5` | `xhigh` | `danger-full-access` | 600s |

**Permission required**: Ask user before using `workspace-write` or `danger-full-access` sandbox modes.

## Core Operations

### Send + Wait + Capture Pattern
Always arm the waiter BEFORE sending the prompt (prevents race condition where a fast response fires the hook before the nonce is written):
```bash
"$CODEX_SCRIPTS/codex-wait-event.sh" "$CODEX_PANE_ID" 300 any &
WAITER_PID=$!
NONCE_PATH="${TMPDIR:-/tmp}/codex-event-state/${CODEX_PANE_ID#%}/nonce"
for i in $(seq 1 10); do [ -f "$NONCE_PATH" ] && break; sleep 0.1; done
tmux-cli send "<PROMPT>" --pane=$CODEX_PANE
wait $WAITER_PID
WAIT_EXIT=$?
if [ "$WAIT_EXIT" -eq 0 ]; then
    tmux-cli capture --pane=$CODEX_PANE
elif [ "$WAIT_EXIT" -eq 2 ]; then
    tmux-cli capture --pane=$CODEX_PANE
    # Handle approval: arm new waiter BEFORE responding
    "$CODEX_SCRIPTS/codex-wait-event.sh" "$CODEX_PANE_ID" 300 any &
    WAITER_PID=$!
    for i in $(seq 1 10); do [ -f "$NONCE_PATH" ] && break; sleep 0.1; done
    # Then send approval (y + Enter) or denial (Esc)
    # Then: wait $WAITER_PID to get the turn completion
elif [ "$WAIT_EXIT" -eq 124 ]; then
    tmux-cli wait_idle --pane=$CODEX_PANE --idle-time=30.0
    tmux-cli capture --pane=$CODEX_PANE
fi
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

Only ask user for config when:
- User explicitly requests different settings
- Task requires write access (`workspace-write` or `danger-full-access`)
- Multiple reasonable approaches exist

Otherwise, use defaults and proceed immediately.

## Error Handling

- **CRITICAL: After starting Codex, ALWAYS capture the pane output and verify Codex launched successfully** before sending any prompts. Look for the Codex banner with model indicator (e.g., `gpt-5.5 xhigh`).
  ```bash
  # After wait_idle on step 4, always verify:
  tmux-cli capture --pane=$CODEX_PANE
  # Check output for Codex banner or errors
  # Only proceed to step 6 if Codex is confirmed running
  ```
- **Codex Update Prompt on Startup**: Codex sometimes shows an "update available" prompt on launch that blocks the TUI. The `codex-update.sh` script (step 1) prevents this by updating before launch. If an update prompt still appears:
  1. Capture the pane output after step 4
  2. Check for update prompt text (e.g., "A new version is available", "Update now?")
  3. If detected: send `y` or Enter to accept the update
  4. Wait for Codex to restart: `tmux-cli wait_idle --pane=$CODEX_PANE --idle-time=60.0`
  5. Re-capture and verify Codex is running with the banner
  6. If Codex exits after update, kill the window and restart from step 3
- **MCP Server Failures Block Codex**: If you see warnings like "MCP startup incomplete (failed: figma)" and Codex doesn't respond to ANY prompts (including "/help" or "Hello"), MCP server initialization failure is blocking Codex.
  - **Solution**: Temporarily disable MCP servers in `~/.codex/config.toml` by removing or commenting out the `[mcp.servers.*]` sections
  - **Root cause**: Failed MCP server initialization (e.g., missing credentials, network issues) can prevent Codex from processing input
  - After completing your work, restore the original config to avoid breaking user's normal workflow
- **Event-driven wait fails**: Falls back to `wait_idle` automatically on timeout (exit 124). No manual intervention needed.
- **Codex exits unexpectedly**: capture output to see error, restart from step 3
- **Window closes**: check `tmux list-windows -t tmux-cli`, recreate window and update `CODEX_WIN`/`CODEX_PANE`/`CODEX_PANE_ID`
- **Hook installation issues**: Run `"$CODEX_SCRIPTS/codex-install-hooks.sh"` manually. Check `~/.codex/hooks.json` for hook entries. Backup is at `~/.codex/hooks.json.pre-skill-backup`.
- **Auth issues**: user must fix credentials outside session

## Cleanup (MANDATORY)

**You MUST close the Codex window when the session is complete.** Always run step 7 after all interactions are done:
```bash
# Try graceful exit, then force-kill to guarantee cleanup
tmux-cli send "/exit" --pane=$CODEX_PANE && \
tmux-cli wait_idle --pane=$CODEX_PANE --idle-time=5.0 || true
tmux kill-window -t "tmux-cli:$CODEX_WIN" 2>/dev/null || true
```

If the window is already dead (Codex crashed or exited on its own), still ensure cleanup:
```bash
tmux kill-window -t "tmux-cli:$CODEX_WIN" 2>/dev/null || true
```

**Never leave a Codex window running after the task is finished.**

## Notes

- Use short flags: `-m` (model), `-c` (config), `-s` (sandbox)
- Never use `tmux-cli launch` - use `tmux new-window -t tmux-cli -n <unique-name>` for isolation
- **Always call `codex-update.sh` before launching Codex** to avoid update prompts
- Hook state files are in `${TMPDIR:-/tmp}/codex-event-state/` and cleaned up automatically
- Summarize Codex findings for user after capturing output
