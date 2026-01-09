---
name: running-interactive-commands
description: Use when running interactive CLI commands, scripts, or programs (python, node, debuggers, REPLs, etc.) that require user input or long-running sessions. Controls terminal applications via tmux-cli in isolated tmux session.
allowed-tools: Bash, Read
---

# Running Interactive Commands with tmux-cli

You have access to `tmux-cli` for controlling terminal applications interactively.

## Session Isolation

**CRITICAL: ALL tmux-cli operations MUST use dedicated "tmux-cli" session.**

### Workflow:
1. Ensure tmux-cli session exists: `tmux has-session -t tmux-cli 2>/dev/null || tmux new-session -d -s tmux-cli`
2. Launch commands in tmux-cli session by targeting it explicitly
3. All panes will be in tmux-cli session (format: `tmux-cli:window.pane`)
4. **NEVER** operate in user's existing sessions (main, aezakmi, ccode, nodes, etc.)

### Accessing tmux-cli session:
- Switch to tmux-cli: `tmux switch-client -t tmux-cli` (if in another tmux session)
- Attach to tmux-cli: `tmux attach -t tmux-cli` (if outside tmux)
- View tmux-cli: `tmux attach -t tmux-cli` in separate terminal

## Critical Rules

### 1. Always Launch Shell First IN THE tmux-cli SESSION
The most important rule: **Always launch a shell in the tmux-cli session using raw tmux commands.**

If you launch a command directly and it errors, the pane closes immediately and you lose all output!

```bash
# GOOD - Launch shell in tmux-cli session using raw tmux
tmux split-window -t tmux-cli -h -P -F '#{session_name}:#{window_index}.#{pane_index}' zsh
# Returns pane ID like tmux-cli:0.1
tmux-cli send "your-command" --pane=tmux-cli:0.1

# BAD - tmux-cli launch creates panes in CURRENT window, not tmux-cli session!
tmux-cli launch "zsh"  # WRONG! This runs in your current session/window!
```

### 2. Use wait_idle Instead of Polling
Avoid performance issues by using `wait_idle` instead of repeatedly calling `capture`:

```bash
# GOOD - Efficient approach
tmux-cli send "command" --pane=tmux-cli:1.2
tmux-cli wait_idle --pane=tmux-cli:1.2 --idle-time=3.0
tmux-cli capture --pane=tmux-cli:1.2

# BAD - Wasteful polling
tmux-cli send "command" --pane=tmux-cli:1.2
# Don't repeatedly call capture in a loop!
```

### 3. Python Interactive Shell Configuration
When starting a Python interactive shell, set the environment variable:

```bash
tmux-cli send "PYTHON_BASIC_REPL=1 python3" --pane=tmux-cli:1.2
```

The non-basic console interferes with send-keys functionality.

### 4. Custom Delays for Reliability
Use custom delays for better control over command timing:

```bash
# Custom 0.5s delay
tmux-cli send "command" --pane=tmux-cli:1.2 --delay-enter=0.5

# Send without Enter
tmux-cli send "text" --pane=tmux-cli:1.2 --enter=False

# Send immediately without delay
tmux-cli send "text" --pane=tmux-cli:1.2 --delay-enter=False
```

### 5. Always Exit Interactive Sessions When Done
**CRITICAL: After completing a task in an interactive session (REPL, debugger, etc.), you MUST exit the session and clean up the pane.**

Once you have captured the output and the task is finished:
1. Exit the interactive program gracefully (e.g., `exit()` for Python, `.exit` for Node.js, `quit` for pdb/gdb)
2. Kill the pane to free resources

```bash
# GOOD - Exit REPL and clean up after task completion
tmux-cli send "3*3" --pane=tmux-cli:0.1
tmux-cli wait_idle --pane=tmux-cli:0.1
tmux-cli capture --pane=tmux-cli:0.1  # Got the result: 9
tmux-cli send "exit()" --pane=tmux-cli:0.1  # Exit Python REPL
tmux kill-pane -t tmux-cli:0.1  # Clean up

# BAD - Leaving REPL running after task is done
tmux-cli send "3*3" --pane=tmux-cli:0.1
tmux-cli capture --pane=tmux-cli:0.1
# Forgot to exit! Python REPL is still running...
```

Exit commands for common interactive sessions:
- **Python REPL**: `exit()` or `quit()`
- **Node.js REPL**: `.exit`
- **pdb/ipdb**: `quit` or `q`
- **gdb/lldb**: `quit` or `q`
- **IRB (Ruby)**: `exit`
- **psql**: `\q`
- **mysql**: `exit`

## Common Commands

### Launching Panes (use raw tmux - NOT tmux-cli launch)
```bash
# Launch shell in tmux-cli session (returns pane ID like tmux-cli:0.1)
tmux split-window -t tmux-cli -h -P -F '#{session_name}:#{window_index}.#{pane_index}' zsh
```

**WARNING**: Do NOT use `tmux-cli launch` - it creates panes in the current window, not in the tmux-cli session!

### Other Operations (use tmux-cli)
- `tmux-cli send "command" --pane=ID` - Send command to pane (default 1s delay before Enter)
- `tmux-cli capture --pane=ID` - Get current pane output
- `tmux-cli wait_idle --pane=ID --idle-time=3.0` - Wait for command to finish
- `tmux-cli interrupt --pane=ID` - Send Ctrl+C to pane
- `tmux-cli escape --pane=ID` - Send escape key to pane
- `tmux kill-pane -t ID` - Close pane
- `tmux list-panes -t tmux-cli -F '#{session_name}:#{window_index}.#{pane_index} #{pane_current_command}'` - List panes in tmux-cli session
- `tmux-cli help` - Display full documentation

## Typical Workflow

1. **Ensure tmux-cli session exists**:
   ```bash
   tmux has-session -t tmux-cli 2>/dev/null || tmux new-session -d -s tmux-cli
   ```

2. **ALWAYS launch a shell first in tmux-cli session** (use raw tmux, NOT tmux-cli launch):
   ```bash
   tmux split-window -t tmux-cli -h -P -F '#{session_name}:#{window_index}.#{pane_index}' zsh
   # Example output: tmux-cli:0.1
   ```

3. **Run your command in the shell**:
   ```bash
   tmux-cli send "python script.py" --pane=tmux-cli:0.1
   ```

4. **Wait for completion and capture output**:
   ```bash
   tmux-cli wait_idle --pane=tmux-cli:0.1 --idle-time=2.0
   tmux-cli capture --pane=tmux-cli:0.1
   ```

5. **Interact with the program** (if needed):
   ```bash
   tmux-cli send "user input" --pane=tmux-cli:0.1
   tmux-cli wait_idle --pane=tmux-cli:0.1
   tmux-cli capture --pane=tmux-cli:0.1
   ```

6. **Clean up when done**:
   ```bash
   tmux kill-pane -t tmux-cli:0.1
   ```

## Common Pitfalls

1. **Using `tmux-cli launch` instead of raw tmux** - `tmux-cli launch` creates panes in the current window, NOT in the tmux-cli session! Always use `tmux split-window -t tmux-cli ...`
2. **Launching Commands Directly** - Always use a shell wrapper (zsh) before running commands
3. **Race Conditions** - Use timed polling and wait_idle to avoid races
4. **Session State Confusion** - Always check session status using `capture` to verify state
5. **Operating in Wrong Session** - Verify panes are in tmux-cli session (pane IDs should start with `tmux-cli:`)
6. **Large Scrollback Issues** - Use appropriate idle-time values for long-running commands
7. **Leaving Interactive Sessions Running** - Always exit REPLs/debuggers and kill panes after task completion. Don't leave orphaned sessions consuming resources

## Use Cases

This skill is ideal for:
- Running Python/Node.js/Ruby interactive REPLs
- Debugging with pdb, node inspect, gdb, lldb
- Testing interactive CLI applications requiring user input
- Long-running processes (servers, builds, tests)
- Any CLI tool that needs stdin interaction
- UI development with live reload servers
- Running and testing shell scripts with interactive prompts

## Examples

### Example 1: Python Interactive Session
```bash
# Ensure tmux-cli session exists
tmux has-session -t tmux-cli 2>/dev/null || tmux new-session -d -s tmux-cli

# Launch shell in tmux-cli session (NOT tmux-cli launch!)
tmux split-window -t tmux-cli -h -P -F '#{session_name}:#{window_index}.#{pane_index}' zsh
# Returns: tmux-cli:0.1

# Start Python REPL
tmux-cli send "PYTHON_BASIC_REPL=1 python3" --pane=tmux-cli:0.1
tmux-cli wait_idle --pane=tmux-cli:0.1 --idle-time=1.0

# Send Python commands
tmux-cli send "import math" --pane=tmux-cli:0.1
tmux-cli send "print(math.pi)" --pane=tmux-cli:0.1
tmux-cli wait_idle --pane=tmux-cli:0.1
tmux-cli capture --pane=tmux-cli:0.1

# Exit Python and clean up
tmux-cli send "exit()" --pane=tmux-cli:0.1
tmux kill-pane -t tmux-cli:0.1
```

### Example 2: Running Tests with Watch Mode
```bash
# Ensure tmux-cli session exists
tmux has-session -t tmux-cli 2>/dev/null || tmux new-session -d -s tmux-cli

# Launch shell in tmux-cli session
tmux split-window -t tmux-cli -h -P -F '#{session_name}:#{window_index}.#{pane_index}' zsh
# Returns: tmux-cli:0.2

# Start test watcher
tmux-cli send "npm run test:watch" --pane=tmux-cli:0.2
tmux-cli wait_idle --pane=tmux-cli:0.2 --idle-time=3.0

# Capture initial output
tmux-cli capture --pane=tmux-cli:0.2

# Send command to rerun tests (depends on test runner)
tmux-cli send "a" --pane=tmux-cli:0.2 --enter=False  # Run all tests
tmux-cli wait_idle --pane=tmux-cli:0.2 --idle-time=5.0

# Stop when done
tmux-cli interrupt --pane=tmux-cli:0.2
tmux kill-pane -t tmux-cli:0.2
```

### Example 3: Debugging with pdb
```bash
# Ensure tmux-cli session exists
tmux has-session -t tmux-cli 2>/dev/null || tmux new-session -d -s tmux-cli

# Launch shell in tmux-cli session
tmux split-window -t tmux-cli -h -P -F '#{session_name}:#{window_index}.#{pane_index}' zsh
# Returns: tmux-cli:0.3

# Run script with pdb
tmux-cli send "python -m pdb script.py" --pane=tmux-cli:0.3
tmux-cli wait_idle --pane=tmux-cli:0.3 --idle-time=1.0
tmux-cli capture --pane=tmux-cli:0.3

# Send debugger commands
tmux-cli send "break 10" --pane=tmux-cli:0.3
tmux-cli send "continue" --pane=tmux-cli:0.3
tmux-cli wait_idle --pane=tmux-cli:0.3
tmux-cli capture --pane=tmux-cli:0.3

# Exit debugger
tmux-cli send "quit" --pane=tmux-cli:0.3
tmux kill-pane -t tmux-cli:0.3
```

## Safety Features

- You cannot kill your own pane - prevents accidental session termination
- Launching directly without a shell causes pane closure on command exit (intentional)
- Session isolation protects user's existing tmux workflow

## Getting Help

Run `tmux-cli help` to see full documentation and all available commands.
