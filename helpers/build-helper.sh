#!/bin/bash
# Builds one of aside's helper programs: ./helpers/build-helper.sh whatsapp
#
# People who install aside have no Go, so this fetches a PINNED Go into aside's
# own support folder (never system-wide, never sudo), checks it against a known
# checksum, and builds with it. A developer's existing Go is reused as is.
set -euo pipefail

NAME="${1:?usage: build-helper.sh <name>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SUPPORT="$HOME/Library/Application Support/aside"
GO_VERSION="go1.27.1"
# Tests override these to prove a wrong checksum is refused.
GO_SHA256="${ASIDE_GO_SHA256:-ee215d57e0ec269c60cc9ceca68e6bda321ba9ee5afe24f4b0988703c2d87d12}"
GO_URL="${ASIDE_GO_URL:-https://go.dev/dl/$GO_VERSION.darwin-arm64.tar.gz}"
GO_ROOT="${ASIDE_GO_ROOT:-$SUPPORT/go}"
DEV_GO="$HOME/.aside-dev/go"
OUT="${ASIDE_HELPER_OUT:-$SUPPORT/helpers}/$NAME-helper"

[ -d "$HERE/$NAME" ] || { echo "no helper named $NAME" >&2; exit 1; }

if [ -x "$DEV_GO/bin/go" ] && [ -z "${ASIDE_IGNORE_DEV_GO:-}" ]; then
  GO_ROOT="$DEV_GO"
elif [ ! -x "$GO_ROOT/bin/go" ]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  echo "Downloading $GO_VERSION (once)..." >&2
  curl -fsSL "$GO_URL" -o "$TMP/go.tgz"
  ACTUAL="$(shasum -a 256 "$TMP/go.tgz" | cut -d' ' -f1)"
  if [ "$ACTUAL" != "$GO_SHA256" ]; then
    echo "Go download failed its checksum (got $ACTUAL). Refusing to use it." >&2
    exit 1
  fi
  mkdir -p "$TMP/x"
  tar -xzf "$TMP/go.tgz" -C "$TMP/x"
  mkdir -p "$(dirname "$GO_ROOT")"
  rm -rf "$GO_ROOT"
  mv "$TMP/x/go" "$GO_ROOT"
fi

mkdir -p "$(dirname "$OUT")"
cd "$HERE/$NAME"
GOTOOLCHAIN=local GOFLAGS=-mod=mod "$GO_ROOT/bin/go" build -o "$OUT" .
echo "Built $OUT"
