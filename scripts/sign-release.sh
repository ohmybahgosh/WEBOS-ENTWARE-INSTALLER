#!/bin/sh
# Signs a release's SHA256SUMS with the release key and publishes it.
#
#   scripts/sign-release.sh v2.16.1 [KEY]
#
# The Release workflow builds the release as a draft, so it's never the
# latest one unsigned.  This runs on the maintainer's computer, where the
# private key is (by default ~/.config/webos-release-keys/webos-entware-installer/release.key,
# never in the repository or on GitHub).  It downloads the draft's files,
# checks they match its SHA256SUMS, signs SHA256SUMS (SHA256SUMS.sig, RSA
# with SHA-256, checked by the installer and the TV app against the keys
# built into them), checks the signature against release-signing-key.pub,
# uploads it and publishes the release.  Needs gh (signed in) and openssl.
set -eu
TAG=${1:-}
KEY=${2:-"$HOME/.config/webos-release-keys/webos-entware-installer/release.key"}
case "$TAG" in v[0-9]*.[0-9]*.[0-9]*) ;; *) echo "Usage: $0 vX.Y.Z [KEY]" >&2; exit 2 ;; esac
[ -r "$KEY" ] || { echo "Can't read the release key: $KEY" >&2; exit 1; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
REPO=ohmybahgosh/WEBOS-ENTWARE-INSTALLER
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
gh release download "$TAG" --repo "$REPO" --dir "$D" --pattern '*'
cd "$D"
rm -f SHA256SUMS.sig
sha256sum -c SHA256SUMS
openssl dgst -sha256 -sign "$KEY" -out SHA256SUMS.sig SHA256SUMS
openssl dgst -sha256 -verify "$ROOT/release-signing-key.pub" -signature SHA256SUMS.sig SHA256SUMS
gh release upload "$TAG" --repo "$REPO" SHA256SUMS.sig --clobber
gh release edit "$TAG" --repo "$REPO" --draft=false --latest
echo "Signed and published $TAG."
