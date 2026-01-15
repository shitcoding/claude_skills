# Claude Skills

Custom skills for Claude Code CLI.

## Skills

### tmux-cli

Run interactive CLI commands (Python/Node REPLs, debuggers, long-running processes) in isolated tmux sessions.

**Features:**
- Session isolation - all operations run in dedicated `tmux-cli` session
- Support for REPLs, debuggers (pdb, gdb), test watchers, servers
- Automatic cleanup of interactive sessions after task completion

**Requirements:**
- [tmux](https://github.com/tmux/tmux) - terminal multiplexer
- [tmux-cli](https://github.com/pchalasani/claude-code-tools) - CLI tool for tmux control

**Installation:**
```bash
# Install tmux (macOS)
brew install tmux

# Install tmux (Ubuntu/Debian)
sudo apt install tmux

# Install tmux-cli via uv
uv tool install claude-code-tools
```

**Documentation:** [tmux-cli instructions & FAQ](https://github.com/pchalasani/claude-code-tools/blob/main/docs/tmux-cli-instructions.md)

### codex-cli-interactive

Run interactive Codex CLI sessions for code review, security audits, refactoring, and multi-turn conversations with OpenAI Codex.

**Features:**
- Interactive Codex sessions via tmux-cli isolation
- Configurable model settings (gpt-5-codex, gpt-5)
- Adjustable reasoning effort and sandbox modes
- Task-specific presets for common workflows
- Multi-turn conversation support

**Requirements:**
- [tmux](https://github.com/tmux/tmux) (v3+) - terminal multiplexer
- [tmux-cli](https://github.com/pchalasani/claude-code-tools) - CLI tool for tmux control
- [Codex CLI](https://github.com/openai/codex) - OpenAI's coding assistant CLI
- OpenAI API credentials configured

**Installation:**
```bash
# Install tmux (macOS)
brew install tmux

# Install tmux-cli via uv
uv tool install claude-code-tools

# Install Codex CLI
npm install -g @openai/codex

# Configure OpenAI credentials
export OPENAI_API_KEY="your-api-key"
```

### ticktick

Manage TickTick tasks and projects from the command line with OAuth2 authentication and secure credential storage.

**Features:**
- List, create, update, complete, and abandon tasks
- Manage projects (lists)
- Batch operations for multiple tasks
- JSON output for scripting
- Secure credential storage via `pass` (GPG-encrypted)

**Requirements:**
- [Bun](https://bun.sh/) - JavaScript runtime
- [pass](https://www.passwordstore.org/) - password manager for secure credential storage
- TickTick OAuth app credentials ([create here](https://developer.ticktick.com/manage))

**Installation:**
```bash
# Install bun (macOS/Linux)
curl -fsSL https://bun.sh/install | bash

# Install pass (macOS)
brew install pass

# Install dependencies
cd ~/.claude/skills/ticktick && bun install

# Store credentials in pass
pass insert ticktick-cli/client-id
pass insert ticktick-cli/client-secret

# Authenticate
bun run scripts/ticktick.ts auth
```

## Setup

Skills must be symlinked to `~/.claude/skills/` directory.

```bash
# Create skills directory if it doesn't exist
mkdir -p ~/.claude/skills

# Symlink a skill
ln -s /path/to/claude_skills/tmux-cli ~/.claude/skills/tmux-cli
```

## Adding New Skills

1. Create a directory with your skill name
2. Add `SKILL.md` with frontmatter (name, description, allowed-tools) and instructions
3. Symlink to `~/.claude/skills/`

Example `SKILL.md` structure:
```markdown
---
name: skill-name
description: Brief description of when to use this skill
allowed-tools: Bash, Read, Edit
---

# Skill Title

Instructions for Claude on how to use this skill...
```
