#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
stage=.build/testhost-deb
app="$stage/var/jb/Applications/IcliTestHost.app"
mkdir -p "$app" "$stage/DEBIAN"
xcrun clang -target arm64-apple-ios16.0 -isysroot "$(xcrun --sdk iphoneos --show-sdk-path)" \
  -fobjc-arc -fmodules -fmodules-cache-path=.build/module-cache -framework Foundation -framework UIKit -framework Vision -framework AVFoundation -framework Security \
  Tests/TestHost/main.m -o "$app/IcliTestHost"
cp Tests/TestHost/Info.plist "$app/Info.plist"
ldid -STests/TestHost/entitlements.plist "$app/IcliTestHost"
ldid -STests/TestHost/entitlements.plist "$app"
cat > "$stage/DEBIAN/control" <<'CONTROL'
Package: dev.owngoal.icli.testhost
Name: icli TestHost
Version: 1.0
Architecture: iphoneos-arm64
Maintainer: OwnGoal
Section: Development
Depends: firmware (>= 16.0)
Description: Test-only fixture for icli acceptance
CONTROL
cat > "$stage/DEBIAN/postinst" <<'POSTINST'
#!/var/jb/bin/sh
set -e
/var/jb/usr/bin/uicache -p /var/jb/Applications/IcliTestHost.app
POSTINST
cat > "$stage/DEBIAN/prerm" <<'PRERM'
#!/var/jb/bin/sh
/var/jb/usr/bin/uicache -u /var/jb/Applications/IcliTestHost.app
PRERM
chmod 755 "$stage/DEBIAN/postinst" "$stage/DEBIAN/prerm"
dpkg-deb --root-owner-group -b "$stage" .build/icli-testhost_1.0_iphoneos-arm64.deb
