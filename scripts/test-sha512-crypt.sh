#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# Host-side known-answer test for the SHA-512 crypt that account set-password
# writes, against published and fixed vectors in Tests/SHA512Crypt. Compiles
# the real SHA512Crypt.m; no hashing tool is needed at test time.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
xcrun clang -fobjc-arc -Wall -Wextra -Werror -ISources/IcliPrivate \
  Sources/IcliPrivate/SHA512Crypt.m Tests/SHA512Crypt/main.m \
  -framework Foundation -framework Security -o "$work/sha512-crypt-tests"
"$work/sha512-crypt-tests" Tests/SHA512Crypt/vectors.json
