#!/bin/bash
# Installs aside. to ~/Applications and starts it at login.
# Run this instead of build.sh when you want the real, permanent copy.
set -euo pipefail
cd "$(dirname "$0")"

DEST="$HOME/Applications/Aside.app"

./build.sh
pkill -f "Aside.app/Contents/MacOS/Aside" 2>/dev/null || true
sleep 1

mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R build/Aside.app "$DEST"
codesign --force --sign - --identifier com.espyagency.aside "$DEST" >/dev/null 2>&1 || true

open "$DEST"

# Preferences are flushed asynchronously, so poll rather than guess a sleep.
status=""
for _ in $(seq 1 20); do
  status=$(defaults read com.espyagency.aside loginItemStatus 2>/dev/null || true)
  [ -n "$status" ] && break
  sleep 0.5
done

echo
echo "Installed to $DEST"
echo "Running from: $(defaults read com.espyagency.aside runningFrom 2>/dev/null || echo unknown)"
echo "Login item:   $(defaults read com.espyagency.aside loginItemStatus 2>/dev/null || echo unknown)"
case "$(defaults read com.espyagency.aside loginItemStatus 2>/dev/null || true)" in
  enabled) echo "Starts automatically at login." ;;
  requiresApproval) echo "Approve it in System Settings > General > Login Items." ;;
  *) echo "Not registered. Use the ... menu, Open at Login." ;;
esac
