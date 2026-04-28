#!/bin/bash
# Update Codex CLI to the latest version.
# Run before launching Codex to avoid the "update available" prompt
# that blocks the TUI and breaks the skill's send/capture flow.
#
# Usage: codex-update.sh
#
# Exit codes:
#   0 = updated or already latest (also on update failure — non-fatal)

set -euo pipefail

# Check if codex is installed
if ! command -v codex &>/dev/null; then
    echo "Error: codex not found on PATH" >&2
    exit 1
fi

CURRENT=$(codex --version 2>/dev/null | head -1 || echo "unknown")
echo "Current version: $CURRENT"

# Detect install method and update accordingly
if command -v brew &>/dev/null && brew list --cask codex &>/dev/null 2>&1; then
    echo "Updating via Homebrew..."
    brew upgrade --cask codex 2>&1 || true
elif command -v npm &>/dev/null && npm list -g @openai/codex &>/dev/null 2>&1; then
    echo "Updating via npm..."
    npm update -g @openai/codex 2>&1 || true
elif command -v npx &>/dev/null; then
    echo "Updating via npx..."
    npx @openai/codex@latest --version 2>&1 || true
else
    echo "Warning: could not detect install method. Run 'codex' manually to check for updates." >&2
    exit 0
fi

UPDATED=$(codex --version 2>/dev/null | head -1 || echo "unknown")
echo "Updated version: $UPDATED"

if [ "$CURRENT" != "$UPDATED" ]; then
    echo "Codex updated: $CURRENT -> $UPDATED"
else
    echo "Codex already at latest version: $CURRENT"
fi
