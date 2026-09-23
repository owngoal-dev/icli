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
ENTITLEMENTS=$(ldid -e "$BIN")
[ -n "$ENTITLEMENTS" ] || { echo 'icli has no signed entitlements' >&2; exit 65; }
rm -rf "$STAGE"
STAGED_BIN="$STAGE$PREFIX/usr/bin/icli"
DOC="$STAGE$PREFIX/usr/share/doc/icli"
mkdir -p "$STAGE/DEBIAN" "$STAGE$PREFIX/usr/bin" "$DOC/licenses"
cp "$BIN" "$STAGED_BIN"
chmod 755 "$STAGED_BIN"
cp "$ROOT/Resources/Licenses/"*.txt "$DOC/licenses/"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$ROOT/LICENSE" "$DOC/"
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
cmp "$BIN" "$STAGED_BIN"
echo "built $OUTPUT"
