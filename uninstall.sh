#!/bin/bash
# Removes aside. completely: the app, the launch agent, and its preferences.
# Your notes are left exactly where they are.
set -euo pipefail
LABEL="com.espyagency.aside"

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
pkill -f "Aside.app/Contents/MacOS/Aside" 2>/dev/null || true
rm -rf "$HOME/Applications/Aside.app"
defaults delete "$LABEL" 2>/dev/null || true

echo "Removed aside. Your notes were not touched."
