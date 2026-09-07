#!/bin/sh
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KIND="${1:-rootless}"
BIN="$ROOT/.build/icli"
VERSION=$(python3 -c 'import plistlib, sys; print(plistlib.load(open(sys.argv[1], "rb"))["CFBundleShortVersionString"])' "$ROOT/Resources/Info.plist")
STAGE="$ROOT/.build/deb-$KIND"
case "$KIND" in
  rootless) ARCH=iphoneos-arm64; PREFIX=/var/jb ;;
  roothide) ARCH=iphoneos-arm64e; PREFIX= ;;
  rootful) ARCH=iphoneos-arm; PREFIX= ;;
  *) echo "unknown package layout: $KIND" >&2; exit 64 ;;
esac
[ -f "$BIN" ] || { echo 'build icli first' >&2; exit 66; }
# Sign once in the build. Packaging must preserve the exact same executable.
ldid -e "$BIN" > "$ROOT/.build/signed-entitlements.plist"
[ -s "$ROOT/.build/signed-entitlements.plist" ] || { echo 'icli has no signed entitlements' >&2; exit 65; }
rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN" "$STAGE$PREFIX/usr/bin"
cp "$BIN" "$STAGE$PREFIX/usr/bin/icli"
chmod 755 "$STAGE$PREFIX/usr/bin/icli"
mkdir -p "$STAGE$PREFIX/usr/share/doc/icli/licenses"
cp "$ROOT/Resources/Licenses/"*.txt "$STAGE$PREFIX/usr/share/doc/icli/licenses/"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$ROOT/LICENSE" "$STAGE$PREFIX/usr/share/doc/icli/"
cat > "$STAGE/DEBIAN/control" <<CONTROL
Package: com.icli.icli
Name: icli
Version: $VERSION
Architecture: $ARCH
Maintainer: icli
Depends: firmware (>= 16.0)
Section: Development
Description: On-device iOS control CLI
CONTROL
OUTPUT="$ROOT/.build/com.icli.icli_${VERSION}_${ARCH}.deb"
dpkg-deb --root-owner-group -b "$STAGE" "$OUTPUT"
cmp "$BIN" "$STAGE$PREFIX/usr/bin/icli"
echo "built $OUTPUT"
