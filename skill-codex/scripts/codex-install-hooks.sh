#!/bin/bash
# One-time idempotent installation of Codex hooks for event-driven detection.
# 1. Enables codex_hooks feature flag in ~/.codex/config.toml
# 2. Appends Stop and PermissionRequest hooks to ~/.codex/hooks.json
#
# Safe to run multiple times. Each concern checked independently.
# NEVER overwrites existing user hooks -- only appends if our hook is missing.
# Uses atomic temp+rename for hooks.json to prevent corruption.

set -euo pipefail

CODEX_DIR="$HOME/.codex"
HOOKS_FILE="$CODEX_DIR/hooks.json"
CONFIG_FILE="$CODEX_DIR/config.toml"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/codex-hook-signal.sh"

# Ensure hook script exists and is executable
if [ ! -x "$HOOK_SCRIPT" ]; then
    echo "Error: hook script not found or not executable: $HOOK_SCRIPT" >&2
    exit 1
fi

# Ensure codex config directory exists
mkdir -p "$CODEX_DIR"

# --- Step 1: Enable codex_hooks feature flag in config.toml ---
# Uses python3 to properly parse and update, handling: already true, set to false,
# commented out, missing [features] section, or missing file entirely.
python3 - "$CONFIG_FILE" <<'PYEOF'
import re, sys, os, tempfile

config_path = sys.argv[1]

if os.path.exists(config_path):
    with open(config_path) as f:
        content = f.read()
else:
    content = ''

# Check if already enabled (uncommented, set to true)
if re.search(r'^codex_hooks\s*=\s*true\s*$', content, re.MULTILINE):
    print('Feature flag: already enabled')
else:
    # Replace existing codex_hooks = false/true (uncommented) with true
    if re.search(r'^codex_hooks\s*=', content, re.MULTILINE):
        content = re.sub(r'^(codex_hooks\s*=\s*).*$', r'\1true', content, count=1, flags=re.MULTILINE)
    elif '[features]' in content:
        # [features] section exists but no codex_hooks line
        content = re.sub(r'(\[features\][^\[]*)', r'\1codex_hooks = true\n', content, count=1, flags=re.DOTALL)
    else:
        # No [features] section at all
        content = content.rstrip() + '\n\n[features]\ncodex_hooks = true\n'

    # Atomic write via temp+rename
    config_dir = os.path.dirname(config_path) or '.'
    os.makedirs(config_dir, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=config_dir)
    with os.fdopen(fd, 'w') as f:
        f.write(content)
    os.rename(tmp, config_path)
    print('Feature flag: enabled')
PYEOF

# --- Step 2: Install hooks in hooks.json (append-only, preserve existing) ---
# Backup existing hooks.json once (before first modification ever)
if [ -f "$HOOKS_FILE" ]; then
    BACKUP="$HOOKS_FILE.pre-skill-backup"
    if [ ! -f "$BACKUP" ]; then
        cp "$HOOKS_FILE" "$BACKUP"
        echo "Backup saved to: $BACKUP"
    fi
fi

# Check which hooks need installing and append only what's missing
# Pass hook_script path as argv to avoid quoting issues
python3 - "$HOOKS_FILE" "$HOOK_SCRIPT" <<'PYEOF'
import json, tempfile, os, sys

hooks_path = sys.argv[1]
hook_script = sys.argv[2]

# Load existing or start fresh
if os.path.exists(hooks_path):
    with open(hooks_path) as f:
        cfg = json.load(f)
else:
    cfg = {}

hooks = cfg.setdefault('hooks', {})

def has_our_hook(event_name):
    """Check if our hook command is already present in an event's rule list."""
    for rule in hooks.get(event_name, []):
        for h in rule.get('hooks', []):
            if h.get('type') == 'command' and h.get('command') == hook_script:
                return True
    return False

def our_rule(matcher=None):
    """Create a hook rule for our script."""
    rule = {'hooks': [{'type': 'command', 'command': hook_script, 'timeout': 5}]}
    if matcher is not None:
        rule['matcher'] = matcher
    return rule

changed = False

# Stop: fires on turn completion (no matcher needed)
if not has_our_hook('Stop'):
    hooks.setdefault('Stop', []).append(our_rule())
    changed = True
    print('Hooks: Stop hook appended')
else:
    print('Hooks: Stop hook already present')

# PermissionRequest: fires on approval prompts (match all tools)
if not has_our_hook('PermissionRequest'):
    hooks.setdefault('PermissionRequest', []).append(our_rule(matcher='.*'))
    changed = True
    print('Hooks: PermissionRequest hook appended')
else:
    print('Hooks: PermissionRequest hook already present')

if changed:
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(hooks_path) or '.')
    with os.fdopen(fd, 'w') as f:
        json.dump(cfg, f, indent=2)
    os.rename(tmp, hooks_path)
    print('Hooks: hooks.json updated')
else:
    print('Hooks: no changes needed')
PYEOF

echo "Hook installation complete"
