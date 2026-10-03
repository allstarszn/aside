#!/bin/bash
# The version contract: VERSION is the one source, the built Info.plist carries it,
# and a missing or malformed VERSION fails loudly instead of building a lie.
# Run by test.sh. Prints "  ok" / "  FAIL" lines like the Swift suite.
cd "$(dirname "$0")/.."
source ./version.sh
fails=0
check() { if [ "$2" = "ok" ]; then echo "  ok    $1"; else echo "  FAIL  $1"; fails=$((fails + 1)); fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

echo "version"
want="$(aside_version "$PWD")" || want=""
check "VERSION is major.minor.patch" "$([ -n "$want" ] && echo ok || echo no)"

aside_write_plist "$tmp/Info.plist" "$PWD" 2>/dev/null
short="$(plutil -extract CFBundleShortVersionString raw "$tmp/Info.plist" 2>/dev/null || true)"
build="$(plutil -extract CFBundleVersion raw "$tmp/Info.plist" 2>/dev/null || true)"
check "the plist's CFBundleShortVersionString is exactly VERSION" "$([ -n "$want" ] && [ "$short" = "$want" ] && echo ok || echo no)"
check "the plist has a CFBundleVersion" "$([ -n "$build" ] && echo ok || echo no)"
check "the plist is valid" "$(plutil -lint "$tmp/Info.plist" >/dev/null 2>&1 && echo ok || echo no)"

mkdir "$tmp/none"
check "a missing VERSION fails loudly" "$(aside_version "$tmp/none" >/dev/null 2>&1 && echo no || echo ok)"
for bad in "1.1" "v1.1.0" "1.1.0-beta" "abc" ""; do
  mkdir -p "$tmp/bad"; printf '%s\n' "$bad" > "$tmp/bad/VERSION"
  check "VERSION '$bad' is refused" "$(aside_version "$tmp/bad" >/dev/null 2>&1 && echo no || echo ok)"
done
# A shallow clone must not report a commit count of 1 as the build number.
mkdir "$tmp/vv"; printf '2.3.4\n' > "$tmp/vv/VERSION"
check "outside git the build number falls back to VERSION" "$([ "$(aside_build_number "$tmp/vv" 2.3.4)" = "2.3.4" ] && echo ok || echo no)"
[ "$fails" -eq 0 ]
