# Claude Skills

Custom skills for Claude Code CLI.

## Skills

### tmux-cli

Run interactive CLI commands (Python/Node REPLs, debuggers, long-running processes) in isolated tmux sessions.

**Features:**
- Session isolation - all operations run in dedicated `tmux-cli` session
- Support for REPLs, debuggers (pdb, gdb), test watchers, servers
- Automatic cleanup of interactive sessions after task completion

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
