#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# Host-side regression for the ledger behind `device passcode unlock`:
# compiles the pure PasscodeLedger.swift on its own against a stub IcliError,
# so it needs nothing from the device or the package build.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
xcrun swiftc -swift-version 5 -module-cache-path "$work/modules" \
  Tests/PasscodeLedger/main.swift Sources/IcliKit/Device/PasscodeLedger.swift \
  -o "$work/passcode-ledger-tests"
"$work/passcode-ledger-tests" "$work/ledgers"
