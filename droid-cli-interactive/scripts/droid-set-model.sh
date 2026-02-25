#!/bin/bash
# Set the Droid model and reasoning effort in ~/.factory/settings.json.
# Must be called BEFORE launching Droid (Droid reads settings at startup).
# Uses atomic temp+rename to prevent file corruption.
#
# Usage: droid-set-model.sh <model_id> <reasoning_effort>
#   model_id:         e.g., gemini-3.1-pro-preview, gpt-5.3-codex, claude-opus-4-6
#   reasoning_effort: e.g., high, xhigh, max

set -euo pipefail

MODEL_ID="${1:?model_id required}"
REASONING="${2:?reasoning_effort required}"
SETTINGS="$HOME/.factory/settings.json"

# Ensure settings file exists
if [ ! -f "$SETTINGS" ]; then
    mkdir -p "$(dirname "$SETTINGS")"
    echo '{}' > "$SETTINGS"
fi

python3 -c "
import json, tempfile, os

settings_path = '$SETTINGS'
model_id = '$MODEL_ID'
reasoning = '$REASONING'

with open(settings_path) as f:
    cfg = json.load(f)

defaults = cfg.setdefault('sessionDefaultSettings', {})
defaults['model'] = model_id
defaults['reasoningEffort'] = reasoning

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(settings_path))
with os.fdopen(fd, 'w') as f:
    json.dump(cfg, f, indent=2)
os.rename(tmp, settings_path)
print(f'Model set: {model_id} ({reasoning})')
"
