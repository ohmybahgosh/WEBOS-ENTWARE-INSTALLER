#!/bin/sh
# Build the Entware TV app (IPK) and its Homebrew Channel manifest.
#
# Usage: webos-app/build.sh [version]
#   version  like 2.7.0 (default: the installer script's VERSION)
# Needs: ares-package (npm install -g @webos-tools/cli), node and npm.
# Output: webos-app/out/<id>_<version>_all.ipk and <id>.manifest.json
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SCRIPT="$ROOT/webos-entware-installer.sh"

SV=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$SCRIPT")
case "$SV" in *.*.*) DEF=$SV ;; *) DEF="$SV.0" ;; esac
VERSION=${1:-$DEF}
case "$VERSION" in [0-9]*.[0-9]*.[0-9]*) ;; *) echo "Version must look like 2.7.0, got $VERSION" >&2; exit 1 ;; esac

DIST="$HERE/dist"
OUT="$HERE/out"
rm -rf "$DIST" "$OUT"
mkdir -p "$DIST/assets" "$OUT"
cp -R "$HERE/src/." "$DIST/"
cp "$SCRIPT" "$DIST/assets/webos-entware-installer.sh"
chmod 755 "$DIST/assets/webos-entware-installer.sh"
# The phone dashboard, served from the TV by 'webos-entware web start'
mkdir -p "$DIST/assets/web"
cp "$HERE/web/server.js" "$HERE/web/index.html" "$HERE/web/dash.js" "$HERE/web/dash.css" "$HERE/web/icon.png" "$DIST/assets/web/"
cp "$ROOT/LICENSE" "$DIST/LICENSE"

# QR code library (MIT, by Kazuhiko Arase), fetched from npm and checked
QR_VERSION=1.4.4
QR_SHA256=18ae399f81182bc9de916e9c77b195df20cc58d6f2d55a62b085a299f1bf1780
mkdir -p "$DIST/vendor" "$HERE/.cache"
QR_CACHE="$HERE/.cache/qrcode-$QR_VERSION.js"
if [ ! -f "$QR_CACHE" ]; then
    TMP=$(mktemp -d)
    (cd "$TMP" && npm pack --silent "qrcode-generator@$QR_VERSION" >/dev/null && tar xzf "qrcode-generator-$QR_VERSION.tgz")
    cp "$TMP/package/qrcode.js" "$QR_CACHE"
    rm -rf "$TMP"
fi
echo "$QR_SHA256  $QR_CACHE" | sha256sum -c - >/dev/null || { echo "qrcode.js checksum mismatch" >&2; rm -f "$QR_CACHE"; exit 1; }
cp "$QR_CACHE" "$DIST/vendor/qrcode.js"

node -e '
const fs = require("fs");
const f = process.argv[1];
const a = JSON.parse(fs.readFileSync(f, "utf8"));
a.version = process.argv[2];
fs.writeFileSync(f, JSON.stringify(a, null, 4) + "\n");
' "$DIST/appinfo.json" "$VERSION"

# This version's changelog, shown once in the app after it updates
node -e '
const fs = require("fs");
const [md, ver, out] = process.argv.slice(1);
const text = fs.readFileSync(md, "utf8");
const head = new RegExp("^## \\[" + ver.replace(/\./g, "\\.") + "\\][^\\n]*\\n", "m");
const m = head.exec(text);
let notes = [];
if (m) {
  const body = text.slice(m.index + m[0].length).split(/\n## /)[0];
  // Bullets, joined across wrapped lines, without Markdown
  notes = body.split(/\n- /).slice(1).map((b) => b.split(/\n\n/)[0].replace(/\s*\n\s*/g, " ")
    .replace(/\*\*([^*]+)\*\*/g, "$1").replace(/`([^`]+)`/g, "$1").replace(/\[([^\]]+)\]\([^)]+\)/g, "$1").trim())
    .filter((b) => b && !/^Everything from \[?2\./.test(b))
    // The first sentence of each, so it fits on the screen
    .map((b) => { const i = b.indexOf(".  "); return i > 0 ? b.slice(0, i + 1) : b; }).slice(0, 6);
}
fs.writeFileSync(out, "window.ENTWARE_NOTES = " + JSON.stringify({ version: ver, notes }) + ";\n");
' "$ROOT/CHANGELOG.md" "$VERSION" "$DIST/whatsnew.js"

ares-package --no-minify "$DIST" -o "$OUT" >/dev/null
IPK=$(ls "$OUT"/*.ipk)
echo "Built $IPK"

node "$HERE/gen-manifest.js" "$DIST/appinfo.json" "$IPK" "$OUT"
