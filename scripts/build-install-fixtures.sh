#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
root="$PWD/.build/install-fixtures"
app="$root/Payload/IcliInstallFixture.app"
mkdir -p "$app" "$root/deb/DEBIAN" "$root/deb/var/mobile/Library/Caches/icli-install-test"
cp .build/testhost-deb/var/jb/Applications/IcliTestHost.app/IcliTestHost "$app/IcliTestHost"
python3 - "$app" "$root" <<'PY'
import plistlib,sys
from pathlib import Path
app=Path(sys.argv[1]); root=Path(sys.argv[2])
info=plistlib.load(open('Tests/TestHost/Info.plist','rb'))
info['CFBundleIdentifier']='dev.owngoal.icli.InstallFixture'
info['CFBundleDisplayName']='icli Install Fixture'
info.pop('CFBundleURLTypes',None)
plistlib.dump(info,open(app/'Info.plist','wb'))
ent=plistlib.load(open('Tests/TestHost/entitlements.plist','rb'))
ent['application-identifier']=info['CFBundleIdentifier']
plistlib.dump(ent,open(root/'entitlements.plist','wb'))
PY
ldid -S"$root/entitlements.plist" "$app"
# A separate identity keeps on-device self-tests away from install acceptance.
selftest="$root/SelfTestFixture.app"
mkdir -p "$selftest"
cp "$app/IcliTestHost" "$selftest/IcliTestHost"
python3 - "$app" "$selftest" "$root" <<'PY'
import plistlib, sys
from pathlib import Path
app, fixture, root = map(Path, sys.argv[1:])
info = plistlib.loads((app / 'Info.plist').read_bytes())
info['CFBundleIdentifier'] = 'dev.owngoal.icli.SelfTestFixture'
info['CFBundleDisplayName'] = 'icli Self-Test Fixture'
(fixture / 'Info.plist').write_bytes(plistlib.dumps(info))
ent = plistlib.loads((root / 'entitlements.plist').read_bytes())
ent['application-identifier'] = info['CFBundleIdentifier']
(root / 'selftest-entitlements.plist').write_bytes(plistlib.dumps(ent))
PY
ldid -S"$root/selftest-entitlements.plist" "$selftest/IcliTestHost"
ldid -S"$root/selftest-entitlements.plist" "$selftest"
(cd "$root" && zip -qr icli-install-fixture.ipa Payload)
cat > "$root/deb/DEBIAN/control" <<'CONTROL'
Package: dev.owngoal.icli.installtest
Name: icli install acceptance fixture
Version: 1.0
Architecture: iphoneos-arm64
Maintainer: OwnGoal
Description: Removable data-only installation fixture
CONTROL
printf 'icli installation verified\n' > "$root/deb/var/mobile/Library/Caches/icli-install-test/marker.txt"
dpkg-deb --root-owner-group -b "$root/deb" "$root/icli-install-fixture.deb"
