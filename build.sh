#!/bin/bash
# Builds Aside.app. No Xcode, no Homebrew: Command Line Tools only.
set -euo pipefail
cd "$(dirname "$0")"

# Check VERSION first, so a bad one fails in a second rather than after the compile.
source ./version.sh
aside_version "$PWD" > /dev/null || exit 1

APP="build/Aside.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O \
  -target arm64-apple-macos14.0 \
  -o "$APP/Contents/MacOS/Aside" \
  Sources/*.swift

cp brand/Aside.icns "$APP/Contents/Resources/Aside.icns"

aside_write_plist "$APP/Contents/Info.plist" "$PWD"

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
