#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# Test-only fixtures for scripts/tvos-acceptance.py, in .build/tvos-fixtures:
# the TestHost app as a bundle to register, the same app under another
# identifier as an IPA to install into a container, and the kickstart daemon
# in two versions.
out=.build/tvos-fixtures
sdk="$(xcrun --sdk appletvos --show-sdk-path)"
cc() { xcrun --sdk appletvos clang -target arm64-apple-tvos15.0 -isysroot "$sdk" "$@"; }
rm -rf "$out"
app="$out/IcliTVTestHost.app"
mkdir -p "$app"
cc -fobjc-arc -Wall -Werror -framework Foundation -framework UIKit Tests/TVTestHost/main.m -o "$app/IcliTVTestHost"
cp Tests/TVTestHost/Info.plist "$app/Info.plist"
cp -R "$app" "$out/container.app"
ldid -STests/TVTestHost/entitlements.plist "$app/IcliTVTestHost"

# The container copy gets its own identifier, so both can be registered.
container_id=dev.owngoal.icli.TVTestHost.Container
plutil -replace CFBundleIdentifier -string "$container_id" "$out/container.app/Info.plist"
plutil -replace CFBundleDisplayName -string "icli TV Container" "$out/container.app/Info.plist"
sed "s/dev.owngoal.icli.TVTestHost</$container_id</" Tests/TVTestHost/entitlements.plist > "$out/container-entitlements.plist"
ldid -S"$out/container-entitlements.plist" "$out/container.app/IcliTVTestHost"
mkdir -p "$out/ipa/Payload"
mv "$out/container.app" "$out/ipa/Payload/IcliTVTestHost.app"
(cd "$out/ipa" && zip -qr ../IcliTVTestHostContainer.ipa Payload)
rm -rf "$out/ipa" "$out/container-entitlements.plist"

for version in 1 2; do
  cc -DICLI_DAEMON_VERSION=$version -Wall -Werror Tests/LaunchdKickstart/main.c -o "$out/kickstart-daemon-$version"
  ldid -S "$out/kickstart-daemon-$version"
done
echo "built $out"
