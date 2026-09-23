#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# The layout decides where dpkg puts the app and how maintainer scripts find tools.
KIND="${1:-rootless}"
case "$KIND" in
  rootless) ARCH=iphoneos-arm64; PREFIX=/var/jb ;;
  roothide) ARCH=iphoneos-arm64e; PREFIX= ;;
  *) echo "unknown package layout: $KIND" >&2; exit 64 ;;
esac
stage=.build/testhost-deb
rm -rf "$stage"
app="$stage$PREFIX/Applications/IcliTestHost.app"
mkdir -p "$app" "$stage/DEBIAN"
xcrun clang -target arm64-apple-ios16.0 -isysroot "$(xcrun --sdk iphoneos --show-sdk-path)" \
  -fobjc-arc -fmodules -fmodules-cache-path=.build/module-cache -framework Foundation -framework UIKit -framework Vision -framework AVFoundation -framework Security \
  Tests/TestHost/main.m -o "$app/IcliTestHost"
cp Tests/TestHost/Info.plist "$app/Info.plist"
ldid -STests/TestHost/entitlements.plist "$app/IcliTestHost"
ldid -STests/TestHost/entitlements.plist "$app"
# Keep the executable where build-install-fixtures.sh expects it for every layout.
mkdir -p .build/testhost-app
cp "$app/IcliTestHost" .build/testhost-app/IcliTestHost
cat > "$stage/DEBIAN/control" <<CONTROL
Package: dev.owngoal.icli.testhost
Name: icli TestHost
Version: 1.0
Architecture: $ARCH
Maintainer: OwnGoal
Section: Development
Depends: firmware (>= 16.0)
Description: Test-only fixture for icli acceptance
CONTROL
# RootHide runs maintainer scripts inside the jbroot, so its paths drop the prefix.
cat > "$stage/DEBIAN/postinst" <<POSTINST
#!$PREFIX/bin/sh
set -e
$PREFIX/usr/bin/uicache -p $PREFIX/Applications/IcliTestHost.app
POSTINST
cat > "$stage/DEBIAN/prerm" <<PRERM
#!$PREFIX/bin/sh
$PREFIX/usr/bin/uicache -u $PREFIX/Applications/IcliTestHost.app
PRERM
chmod 755 "$stage/DEBIAN/postinst" "$stage/DEBIAN/prerm"
dpkg-deb --root-owner-group -b "$stage" ".build/icli-testhost_1.0_$ARCH.deb"
