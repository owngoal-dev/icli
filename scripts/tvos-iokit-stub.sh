#!/bin/sh
set -eu
# The AppleTVOS SDK has no IOKit.framework, though tvOS ships one. icli uses
# only the registry walk from it, which tvOS exports as iOS does, so the tvOS
# build borrows the iPhoneOS SDK's headers and stub, retargeted to tvOS.
OUT="${1:?usage: tvos-iokit-stub.sh <framework-search-directory>}"
IOKIT="$(xcrun --sdk iphoneos --show-sdk-path)/System/Library/Frameworks/IOKit.framework/Versions/A"
FRAMEWORK="$OUT/IOKit.framework"
rm -rf "$FRAMEWORK"
mkdir -p "$FRAMEWORK"
cp -R "$IOKIT/Headers" "$FRAMEWORK/Headers"
sed -E 's/arm64e?-ios/arm64-tvos, arm64e-tvos/' "$IOKIT/IOKit.tbd" > "$FRAMEWORK/IOKit.tbd"
grep -q 'arm64-tvos' "$FRAMEWORK/IOKit.tbd" || { echo 'IOKit.tbd has no iOS target to retarget' >&2; exit 65; }
! grep -q -- '-ios[] ,]' "$FRAMEWORK/IOKit.tbd" || { echo 'IOKit.tbd still names an iOS target' >&2; exit 65; }
