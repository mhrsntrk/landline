#!/usr/bin/env bash
# Sign and notarize the macOS binaries of a published release.
#
#   packaging/sign-macos.sh v0.3.0
#
# Run it on a Mac that holds the Developer ID Application certificate. The
# signed, notarized, stapled zips are uploaded back onto the same GitHub
# release, and the plain binaries are left in place for the Homebrew bottle
# path, which does not carry quarantine and does not need them.
#
# Why this is not a CI job: signing in Actions means exporting the Developer ID
# private key as a repository secret, and this repository is public. The key
# stays on the machine that owns it. If that trade is ever worth revisiting,
# what CI would need is the .p12 as a base64 secret, its password, and an App
# Store Connect key for notarytool.
#
# What signing buys, precisely. Installs via `install.sh` or a Homebrew bottle
# attach no quarantine attribute and work unsigned today. A binary downloaded
# from the releases page in a browser *is* quarantined, and current macOS
# refuses to run an unsigned quarantined executable outright; for a CLI there
# is no right-click-open escape, only `xattr -d` or a trip through System
# Settings. Signing also gives the binary a stable identity, so firewall and
# TCC approvals survive an upgrade instead of being asked again.
#
# On stapling: you cannot. `stapler` refuses a bare Mach-O *and* a zip, both
# verified against this very pipeline; it only writes tickets onto .app, .dmg
# and .pkg. So the zip is notarized and shipped unstapled, and Gatekeeper
# fetches the ticket from Apple the first time the binary runs. That needs the
# machine to be online once, which is the trade for not wrapping a single
# executable in a disk image.
set -euo pipefail

TAG="${1:?usage: sign-macos.sh <tag>}"
REPO="${REPO:-mhrsntrk/landline}"

# Pinned by SHA-1, not by name. There are two "Developer ID Application:
# Mahir Senturk" certificates in this keychain and `codesign -s` by name is
# ambiguous between them, which fails in a way that reads like a missing cert.
IDENTITY="${LANDLINE_SIGN_IDENTITY:-3BC298C7024B8E282D3212B8084DB26BB1C4E712}"
# notarytool credentials: an App Store Connect API key.
ASC_KEY_ID="${LANDLINE_ASC_KEY_ID:-39XSB96NBH}"
ASC_ISSUER="${LANDLINE_ASC_ISSUER:-a0713d4e-1a47-4322-8d92-a9b154b9b3e8}"
ASC_KEY="${LANDLINE_ASC_KEY:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"

command -v gh >/dev/null || { echo "gh is required" >&2; exit 1; }
security find-identity -v -p codesigning | grep -q "$IDENTITY" \
  || { echo "signing identity $IDENTITY not in the keychain" >&2; exit 1; }
[ -f "$ASC_KEY" ] || { echo "App Store Connect key not found at $ASC_KEY" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

for target in aarch64-apple-darwin x86_64-apple-darwin; do
  bin="landlined-$target"
  echo "==> $bin"
  gh release download "$TAG" --repo "$REPO" --pattern "$bin" --dir .

  # --options runtime is what notarization requires; --timestamp is what makes
  # the signature outlive the certificate.
  codesign --force --sign "$IDENTITY" \
    --options runtime --timestamp \
    --identifier "dev.landline.landlined" \
    "$bin"
  codesign --verify --strict --verbose=2 "$bin"

  zip -q "${bin}.zip" "$bin"
  echo "    submitting for notarization, this waits on Apple"
  xcrun notarytool submit "${bin}.zip" \
    --key "$ASC_KEY" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER" \
    --wait --timeout 30m

  # No stapling: see the note at the top. `stapler` rejects both the bare
  # binary and the zip. Verify the signature instead, which is what has to hold.
  codesign --verify --strict --verbose=2 "$bin"
  shasum -a 256 "${bin}.zip" > "${bin}.zip.sha256"
done

echo "==> uploading signed zips to $TAG"
gh release upload "$TAG" --repo "$REPO" \
  landlined-*-apple-darwin.zip landlined-*-apple-darwin.zip.sha256 --clobber

cat <<'DONE'

Signed and notarized. The release now carries both forms:

  landlined-<target>            plain binary, what Homebrew and install.sh use
  landlined-<target>.zip        signed and notarized, for a browser download

The zip is not stapled: `stapler` only writes tickets onto .app, .dmg and
.pkg. Gatekeeper fetches the ticket online the first time the binary runs.

DONE
