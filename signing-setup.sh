#!/bin/bash
# Creates a stable, self-signed code signing identity for aside, once.
#
# 🔴 Why this exists. Without it every build is signed "ad-hoc", which makes the
# app a BRAND NEW PROGRAM to macOS each time. So after every ./install.sh:
#   - Full Disk Access has to be granted again
#   - the Slack token in the keychain asks for your password again
#   - "Always Allow" never sticks, because there is nothing stable to remember
# A self-signed identity gives macOS one program to remember. It costs nothing.
#
# It does NOT replace the Apple Developer Program. Gatekeeper still refuses a
# DOWNLOADED copy, so sharing a .dmg with someone still needs the $99 and
# notarization. This fixes the reinstall churn, not distribution.
#
# Run once:  ./signing-setup.sh
# Then the usual ./install.sh picks the identity up on its own.
set -euo pipefail
cd "$(dirname "$0")"

NAME="Aside Self Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "\"$NAME\" already exists. Nothing to do."
  security find-identity -v -p codesigning | grep "$NAME" || true
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A self-signed root, trusted ONLY for code signing further down. Ten years so
# this is not a yearly chore.
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -subj "/CN=$NAME" \
  -addext "basicConstraints=critical,CA:true" \
  -addext "keyUsage=critical,digitalSignature,keyCertSign" \
  -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1

# A throwaway passphrase, not an empty one: Keychain rejects an empty-password
# PKCS#12 outright. The legacy PBE algorithms are deliberate too, since Keychain
# will not read a bundle wrapped with the modern defaults.
PASS="$(openssl rand -hex 16)"
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/identity.p12" -passout "pass:$PASS" \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 >/dev/null 2>&1

echo "Importing the identity. macOS may ask for your login password."
# -T /usr/bin/codesign lets codesign use the key. codesign is Apple's own binary
# and never changes, unlike this app, so "Always Allow" will actually stick.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null

echo "Trusting it for code signing only."
# -p codeSign scopes the trust to code signing. Never a blanket trustRoot: this
# certificate must not be able to vouch for a website.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo
echo "Done. Identity:"
security find-identity -v -p codesigning | grep "$NAME"
echo
echo "Now run ./install.sh. The first build shows one keychain prompt:"
echo "click Always Allow and it will not ask again."
