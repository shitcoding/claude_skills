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

# Check if hooks already installed (idempotent)
if python3 -c "
import json, sys
with open('$SETTINGS') as f:
    cfg = json.load(f)
hooks = cfg.get('hooks', {})
if 'Stop' in hooks:
    entries = hooks['Stop']
    if isinstance(entries, list) and any('$HOOK_SCRIPT' in str(e) for e in entries):
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
python3 -c "
import json, tempfile, os

settings_path = '$SETTINGS'
hook_script = '$HOOK_SCRIPT'

with open(settings_path) as f:
    cfg = json.load(f)

hook_entry = {'command': hook_script}
hooks = cfg.setdefault('hooks', {})
for event in ['Stop', 'SubagentStop', 'Notification']:
    hooks[event] = [hook_entry]

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(settings_path))
with os.fdopen(fd, 'w') as f:
    json.dump(cfg, f, indent=2)
os.rename(tmp, settings_path)
"

echo "Hooks installed successfully"
