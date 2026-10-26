#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# Host-side regression for `icli probe`: the JavaScriptCore runtime, the ObjC
# reflection bridge and its ownership rules, the prelude's globals and absences,
# output capture and its cap, the api() handler mechanism, and the REPL's
# source-completeness scan. Compiles IcliProbe's sources with the test harness
# for the Mac, which has JavaScriptCore, and runs them. No device is needed.
#
# No framework but Foundation is linked: JavaScriptCore is loaded with dlopen,
# the same way the shipped binary does, so a green run also proves that path.
# Zombies stay on so a bridge that releases an object once too often crashes
# the run instead of corrupting memory quietly.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
xcrun --sdk macosx clang -std=gnu11 -fobjc-arc -fobjc-weak -Wall -Wextra -Werror \
  -ISources/IcliProbe -ISources/IcliProbe/include \
  Sources/IcliProbe/IcliProbeContext.m \
  Sources/IcliProbe/IcliProbeBridge.m \
  Sources/IcliProbe/IcliProbeRepl.m \
  Tests/Probe/main.m \
  -framework Foundation \
  -o "$work/probe-tests"
NSZombieEnabled=YES "$work/probe-tests"
