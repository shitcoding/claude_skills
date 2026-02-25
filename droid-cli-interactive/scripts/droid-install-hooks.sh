#!/bin/bash
# One-time idempotent installation of Droid hooks for event-driven detection.
# Injects Stop, SubagentStop, and Notification hooks into ~/.factory/settings.json.
# Safe to run multiple times - checks if hooks are already present.
# Uses atomic temp+rename to prevent file corruption.

set -euo pipefail

SETTINGS="$HOME/.factory/settings.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/droid-hook-signal.sh"

# Ensure hook script exists and is executable
if [ ! -x "$HOOK_SCRIPT" ]; then
    echo "Error: hook script not found or not executable: $HOOK_SCRIPT" >&2
    exit 1
fi

# Ensure settings file exists
if [ ! -f "$SETTINGS" ]; then
    mkdir -p "$(dirname "$SETTINGS")"
    echo '{}' > "$SETTINGS"
fi

# Check if hooks already installed with CORRECT format (idempotent)
# Correct format: {"hooks": [{"type": "command", "command": "..."}]}
# Old wrong format: {"command": "..."} - must be replaced
if python3 -c "
import json, sys
with open('$SETTINGS') as f:
    cfg = json.load(f)
hooks = cfg.get('hooks', {})
if 'Stop' in hooks:
    entries = hooks['Stop']
    if isinstance(entries, list) and len(entries) > 0:
        entry = entries[0]
        # Check for correct nested format
        if 'hooks' in entry and isinstance(entry['hooks'], list):
            for h in entry['hooks']:
                if h.get('type') == 'command' and h.get('command') == '$HOOK_SCRIPT':
                    sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
    echo "Hooks already installed"
    exit 0
fi

# Backup current settings (once, don't overwrite existing backup)
BACKUP="$SETTINGS.pre-hooks-backup"
if [ ! -f "$BACKUP" ]; then
    cp "$SETTINGS" "$BACKUP"
    echo "Backup saved to: $BACKUP"
fi

# Merge hooks using atomic temp+rename
# Droid hook format: {"hooks": [{"type": "command", "command": "..."}]}
# Notification also needs "matcher": "" to match all notifications
python3 -c "
import json, tempfile, os

settings_path = '$SETTINGS'
hook_script = '$HOOK_SCRIPT'

with open(settings_path) as f:
    cfg = json.load(f)

def make_hook_entry(cmd):
    return {'hooks': [{'type': 'command', 'command': cmd}]}

def make_hook_entry_with_matcher(cmd, matcher=''):
    return {'matcher': matcher, 'hooks': [{'type': 'command', 'command': cmd}]}

hooks = cfg.setdefault('hooks', {})

# Stop and SubagentStop: lifecycle events, no matcher needed
for event in ['Stop', 'SubagentStop']:
    hooks[event] = [make_hook_entry(hook_script)]

# Notification: needs matcher field (empty string = match all)
hooks['Notification'] = [make_hook_entry_with_matcher(hook_script)]

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(settings_path))
with os.fdopen(fd, 'w') as f:
    json.dump(cfg, f, indent=2)
os.rename(tmp, settings_path)
"

echo "Hooks installed successfully"
