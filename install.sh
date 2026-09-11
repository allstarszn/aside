#!/bin/bash
# Installs aside. to ~/Applications, starts it at login, and restarts it if it
# ever crashes. Run this instead of build.sh when you want the real copy.
set -euo pipefail
cd "$(dirname "$0")"

DEST="$HOME/Applications/Aside.app"
LABEL="com.espyagency.aside"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

./build.sh

# An older aside started itself with SMAppService. That registration lives in macOS rather
# than in the code, so 9233f2d deleting the code did not remove it, and every login started a
# second copy alongside the agent below. Two processes means two menu bar icons. Silent no-op
# when there is no such item; it needs Automation permission for System Events, so it is
# allowed to fail rather than block the install.
osascript -e 'tell application "System Events" to delete (every login item whose path contains "Aside.app")' >/dev/null 2>&1 || true

# Stop whatever is running, through launchd if it owns it.
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
pkill -f "Aside.app/Contents/MacOS/Aside" 2>/dev/null || true
sleep 1

mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
rm -rf "$DEST"
cp -R build/Aside.app "$DEST"
# Re-signed because copying the bundle invalidates the signature. Uses the
# stable identity when one exists, so the installed copy is the SAME program to
# macOS as the last one and its permissions carry over.
source ./signing-id.sh
IDENTITY="$(aside_signing_identity)"
if ! codesign --force --sign "$IDENTITY" --identifier "$LABEL" "$DEST" >/dev/null 2>&1; then
  echo "warning: could not sign with \"$IDENTITY\", falling back to ad-hoc" >&2
  IDENTITY="-"
  codesign --force --sign - --identifier "$LABEL" "$DEST" >/dev/null 2>&1 || true
fi

# KeepAlive with SuccessfulExit false means: come back after a crash, but respect
# Quit. NSApp.terminate exits cleanly, so quitting really quits.
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>Program</key><string>$DEST/Contents/MacOS/Aside</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key>
  <dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLISTEOF

launchctl bootstrap "gui/$UID" "$PLIST"

# Preferences flush lazily, so poll rather than guessing a sleep.
for _ in $(seq 1 20); do
  [ -n "$(defaults read com.espyagency.aside runningFrom 2>/dev/null || true)" ] && break
  sleep 0.5
done

echo
echo "Installed to $DEST"
echo "Signed with:   $IDENTITY"
[ "$IDENTITY" = "-" ] && echo "  (ad-hoc: run ./signing-setup.sh once to stop the permission prompts returning)"
echo "Running from:  $(defaults read com.espyagency.aside runningFrom 2>/dev/null || echo unknown)"
echo "Starts at login and restarts if it crashes."
echo "To remove it entirely: ./uninstall.sh"
