#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
OUT="${TMPDIR:-/tmp}/steamos-ios-process-test"
rm -rf "$OUT"
mkdir -p "$OUT"
cc -std=c11 -Wall -Wextra -Werror \
  "$ROOT/runtime/linux/process/initial_stack.c" \
  "$ROOT/tests/linux-process/test_initial_stack.c" \
  -o "$OUT/test_initial_stack"
"$OUT/test_initial_stack"
