#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
python3 scripts/check-entitlements.py
./packaging/build-deb.sh rootless
./packaging/build-deb.sh roothide
rm -rf .build/package-check
mkdir -p .build/package-check/rootless .build/package-check/roothide
version=$(python3 -c 'import plistlib; print(plistlib.load(open("Resources/Info.plist", "rb"))["CFBundleShortVersionString"])')
dpkg-deb -x ".build/com.icli.icli_${version}_iphoneos-arm64.deb" .build/package-check/rootless
dpkg-deb -x ".build/com.icli.icli_${version}_iphoneos-arm64e.deb" .build/package-check/roothide
cmp .build/icli .build/package-check/rootless/var/jb/usr/bin/icli
cmp .build/icli .build/package-check/roothide/usr/bin/icli
shasum -a 256 .build/icli .build/package-check/rootless/var/jb/usr/bin/icli .build/package-check/roothide/usr/bin/icli
python3 scripts/verify-packages.py
