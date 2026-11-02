#!/bin/sh
# shellcheck disable=SC2034  # variables are read inside the checks that ok() evals
# Checks a built TV app: what's inside the IPK, that it carries this exact
# installer, and that the Homebrew Channel manifest matches it.
# Usage: tests/check-ipk.sh [out dir]   (default: webos-app/out, after webos-app/build.sh)
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$ROOT/webos-app/out}
IPK=$(ls "$OUT"/*.ipk)
MAN=$(ls "$OUT"/*.manifest.json)
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
FAIL=0
ok() { if eval "$2"; then echo "  PASS $1"; else echo "  FAIL $1"; FAIL=1; fi; }

(cd "$W" && ar x "$IPK" && mkdir data control && tar xzf data.tar.gz -C data && tar xzf control.tar.gz -C control)
APPDIR=$(find "$W/data" -name appinfo.json -exec dirname {} \; | head -n 1)
VERSION=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$ROOT/webos-entware-installer.sh")

ok "the IPK is a webOS package (debian-binary 2.0)" '[ "$(cat "$W/debian-binary")" = 2.0 ]'
ok "it has the app files" 'for f in index.html app.js style.css appinfo.json icon80.png icon130.png icon160.png vendor/qrcode.js LICENSE assets/webos-entware-installer.sh; do [ -s "$APPDIR/$f" ] || { echo "    missing $f"; exit 1; }; done'
ok "it carries this exact installer, executable" 'cmp -s "$APPDIR/assets/webos-entware-installer.sh" "$ROOT/webos-entware-installer.sh" && [ -x "$APPDIR/assets/webos-entware-installer.sh" ]'
ok "nothing unexpected is packed (maps, node_modules, dotfiles)" '[ -z "$(find "$APPDIR" \( -name "*.map" -o -name node_modules -o -name ".*" \) -print)" ]'
ok "the app version matches the installer ($VERSION)" 'node -e "process.exit(require(process.argv[1]).version === process.argv[2] ? 0 : 1)" "$APPDIR/appinfo.json" "$VERSION"'
ok "the control file names the app and version" 'grep -q "^Package: org.ohmybahgosh.entware$" "$W/control/control" && grep -q "^Version: $VERSION$" "$W/control/control"'
ok "the manifest matches the IPK (hash, size, version, URL)" 'node -e "
const m = require(process.argv[1]), fs = require(\"fs\"), crypto = require(\"crypto\"), path = require(\"path\");
const d = fs.readFileSync(process.argv[2]);
const want = crypto.createHash(\"sha256\").update(d).digest(\"hex\");
const url = \"https://github.com/ohmybahgosh/WEBOS-ENTWARE-INSTALLER/releases/download/v\" + process.argv[3] + \"/\" + path.basename(process.argv[2]);
if (m.ipkHash.sha256 !== want || m.ipkSize !== d.length || m.version !== process.argv[3] || m.ipkUrl !== url || m.rootRequired !== true) { console.log(m); process.exit(1); }
" "$MAN" "$IPK" "$VERSION"'
ok "the IPK stays small (under 1 MB)" '[ "$(wc -c < "$IPK")" -lt 1048576 ]'
exit $FAIL
