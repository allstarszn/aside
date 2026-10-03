#!/bin/bash
# Where aside's version comes from. Sourced by build.sh and test.sh.
#
# VERSION at the repo root holds major.minor.patch and nothing else. Bump it there.
# CFBundleShortVersionString is VERSION (it is what the usage ping reports as "v").
# CFBundleVersion is the git commit count when that count is trustworthy, otherwise
# VERSION: the one-line installer makes a --depth 1 clone, where the count is always
# 1 and would make every release look identical, so a shallow clone, a tarball or
# no git at all fall back to VERSION.

aside_version() {
  local file="$1/VERSION" v
  if [ ! -f "$file" ]; then
    echo "VERSION is missing: expected $file containing something like 1.1.0" >&2
    return 1
  fi
  v="$(tr -d '[:space:]' < "$file")"
  if ! [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "VERSION must be major.minor.patch (for example 1.1.0), found: '$v'" >&2
    return 1
  fi
  printf '%s' "$v"
}

aside_build_number() {
  local root="$1" version="$2" count
  if command -v git >/dev/null 2>&1 \
     && [ "$(git -C "$root" rev-parse --is-shallow-repository 2>/dev/null)" = "false" ] \
     && count="$(git -C "$root" rev-list --count HEAD 2>/dev/null)" \
     && [[ "$count" =~ ^[0-9]+$ ]]; then
    printf '%s' "$count"
  else
    printf '%s' "$version"
  fi
}

# Writes Info.plist to $1, with the real version filled in. $2 is the repo root.
aside_write_plist() {
  local out="$1" root="$2" version build
  version="$(aside_version "$root")" || return 1
  build="$(aside_build_number "$root" "$version")"
  cat > "$out" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Aside</string>
  <key>CFBundleDisplayName</key><string>Aside</string>
  <key>CFBundleIdentifier</key><string>com.espyagency.aside</string>
  <key>CFBundleExecutable</key><string>Aside</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>CFBundleIconFile</key><string>Aside</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <!-- How a Slack token gets back into the app. Slack only redirects to HTTPS,
       so the landing site catches the callback and forwards it here. -->
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>com.espyagency.aside</string>
      <key>CFBundleURLSchemes</key><array><string>aside</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST
}
