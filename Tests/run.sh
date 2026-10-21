#!/bin/bash
# Checks the built-in xxHash3-128 against reference vectors.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
swiftc -O -parse-as-library Tests/XXH3Check.swift Sources/XXH3.swift -o "$OUT/xxh3check"
"$OUT/xxh3check" Tests/xxh3_vectors.txt
rm -rf "$OUT"
