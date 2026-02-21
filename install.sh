#!/bin/bash
# install.sh — Claude Code Status Line installer
# Usage: bash install.sh [--refresh SECONDS]
#    or: curl -fsSL https://raw.githubusercontent.com/ohugonnot/claude-code-statusline/main/install.sh | bash -s -- --refresh 60
set -euo pipefail

# Parse arguments
CUSTOM_REFRESH=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --refresh) CUSTOM_REFRESH="$2"; shift 2 ;;
        *) shift ;;
    esac
done

REPO_RAW="https://raw.githubusercontent.com/ohugonnot/claude-code-statusline/main"
HOOKS_DIR="$HOME/.claude/hooks"
SETTINGS_FILE="$HOME/.claude/settings.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-/dev/null}")" 2>/dev/null && pwd || echo "")"

echo "=== Claude Code Status Line Installer ==="

# 1. Check dependencies and offer to install missing ones
echo ""
echo "Checking dependencies..."

MISSING=()
for dep in jq tmux python3; do
    if command -v "$dep" >/dev/null 2>&1; then
        echo "  [ok] $dep"
    else
        echo "  [missing] $dep"
        MISSING+=("$dep")
    fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    echo ""
    read -rp "Install missing packages (${MISSING[*]})? [Y/n] " answer
    if [[ -z "$answer" || "$answer" =~ ^[Yy] ]]; then
        sudo apt install -y "${MISSING[@]}"
        echo "  Packages installed."
    else
        echo "  Skipped. Some features may not work without: ${MISSING[*]}"
    fi
fi

# 2. Install statusline.sh
echo ""
echo "Installing statusline.sh..."

mkdir -p "$HOOKS_DIR"

if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/statusline.sh" ]; then
    cp "$SCRIPT_DIR/statusline.sh" "$HOOKS_DIR/statusline.sh"
else
    echo "  Downloading from GitHub..."
    curl -fsSL "$REPO_RAW/statusline.sh" -o "$HOOKS_DIR/statusline.sh"
fi
chmod +x "$HOOKS_DIR/statusline.sh"

# Apply custom refresh interval if provided
if [ -n "$CUSTOM_REFRESH" ]; then
    sed -i "s/REFRESH_INTERVAL=\"\${REFRESH_INTERVAL:-300}\"/REFRESH_INTERVAL=\"\${REFRESH_INTERVAL:-$CUSTOM_REFRESH}\"/" "$HOOKS_DIR/statusline.sh"
    echo "  Refresh interval set to ${CUSTOM_REFRESH}s"
fi

echo "  Installed: $HOOKS_DIR/statusline.sh"

# 3. Update settings.json
echo ""
echo "Configuring Claude Code..."

STATUS_LINE_CONFIG='{"type":"command","command":"bash ~/.claude/hooks/statusline.sh"}'

if [ -f "$SETTINGS_FILE" ]; then
    tmp="$(mktemp)"
    jq --argjson sl "$STATUS_LINE_CONFIG" '. + {statusLine: $sl}' "$SETTINGS_FILE" > "$tmp"
    mv "$tmp" "$SETTINGS_FILE"
    echo "  Merged statusLine into existing settings.json"
else
    mkdir -p "$(dirname "$SETTINGS_FILE")"
    jq -n --argjson sl "$STATUS_LINE_CONFIG" '{statusLine: $sl}' > "$SETTINGS_FILE"
    echo "  Created settings.json with statusLine config"
fi

# 4. Done
echo ""
echo "Done! Restart Claude Code to see the status line."
echo ""
echo "Test command:"
echo "  echo '{\"model\":\"claude-sonnet-4-6\",\"context_window\":{\"used_percentage\":42}}' | bash $HOOKS_DIR/statusline.sh"
