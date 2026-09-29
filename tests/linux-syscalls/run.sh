#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
OUT="${TMPDIR:-/tmp}/steamos-ios-syscall-test"
rm -rf "$OUT"
mkdir -p "$OUT"
cc -std=c11 -Wall -Wextra -Werror \
  "$ROOT/runtime/linux/syscalls/syscall_dispatch.c" \
  "$ROOT/tests/linux-syscalls/test_dispatch.c" \
  -o "$OUT/test_dispatch"
"$OUT/test_dispatch"
