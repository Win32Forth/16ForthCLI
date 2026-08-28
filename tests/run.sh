#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BIN=/tmp/16ForthCLI
clang -arch arm64 -o "$BIN" 16ForthCLI/kernel.s 16ForthCLI/host_io.c -I "$ROOT"

out="$("$BIN" < tests/smoke.fth)"
echo "$out"

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "$out" | grep -q '^3$'           || fail "1 2 + did not print ASCII 3"
echo "$out" | grep -q '14 '           || fail "colon DBL did not print 14"
echo "$out" | grep -q '^P$'           || fail "IF true branch did not print P"

echo "PASS"
