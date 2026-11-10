#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# Build the actual pure C geometry core and Swift scope API without UIKit or
# the package's Apple-only dependencies. Works on Linux and macOS.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cat > "$work/module.modulemap" <<EOF
module IcliPrivate {
    header "$PWD/Sources/IcliPrivate/include/IcliInterfaceGeometry.h"
    export *
}
EOF
"${CC:-clang}" -std=c11 -Wall -Wextra -Werror -ISources/IcliPrivate/include \
  -c Sources/IcliPrivate/InterfaceGeometry.c -o "$work/geometry.o"
"${SWIFTC:-swiftc}" -swift-version 6 -warnings-as-errors -module-cache-path "$work/modules" -I "$work" \
  Tests/InterfaceGeometry/main.swift Sources/IcliKit/Input/InterfaceGeometry.swift \
  "$work/geometry.o" -o "$work/interface-geometry-tests"
"$work/interface-geometry-tests"
