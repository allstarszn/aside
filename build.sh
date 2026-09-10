#!/bin/bash
# Builds Aside.app. No Xcode, no Homebrew: Command Line Tools only.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Aside.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O \
  -target arm64-apple-macos14.0 \
  -o "$APP/Contents/MacOS/Aside" \
  Sources/*.swift

cp brand/Aside.icns "$APP/Contents/Resources/Aside.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Aside</string>
  <key>CFBundleDisplayName</key><string>Aside</string>
  <key>CFBundleIdentifier</key><string>com.espyagency.aside</string>
  <key>CFBundleExecutable</key><string>Aside</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>CFBundleIconFile</key><string>Aside</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

source ./signing-id.sh
IDENTITY="$(aside_signing_identity)"
if ! codesign --force --sign "$IDENTITY" --identifier com.espyagency.aside "$APP" >/dev/null 2>&1; then
  # A broken identity must not stop a dev build, but it must not be silent
  # either: signing ad-hoc is exactly what makes the permission prompts return.
  echo "warning: could not sign with \"$IDENTITY\", falling back to ad-hoc" >&2
  IDENTITY="-"
  codesign --force --sign - --identifier com.espyagency.aside "$APP" >/dev/null 2>&1 || true
fi
echo "Built $APP (signed: $IDENTITY)"
