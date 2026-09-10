# Sourced by build.sh and install.sh. Echoes the code signing identity to use.
#
# A stable identity is what lets macOS remember this app across reinstalls, so
# Full Disk Access and the keychain stop re-asking. Without one we fall back to
# ad-hoc, which still runs locally but is a new program every single build.
# Create the identity once with ./signing-setup.sh.
aside_signing_identity() {
  local name="Aside Self Signed"
  if security find-identity -v -p codesigning 2>/dev/null | grep -q "$name"; then
    printf '%s' "$name"
  else
    printf '%s' "-"
  fi
}
