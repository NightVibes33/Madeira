#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
OUT="${TMPDIR:-/tmp}/steamos-ios-elf-test"
rm -rf "$OUT"
mkdir -p "$OUT"
python3 "$ROOT/tests/elf/gen_static_smoke.py"     --elf "$OUT/steamos_ios_static_smoke.elf"     --header "$OUT/steamos_ios_static_smoke.h"
cc -std=c11 -Wall -Wextra -Werror     "$ROOT/runtime/linux/elf/elf64_image.c"     "$ROOT/tests/elf/test_elf64_image.c"     -o "$OUT/test_elf64_image"
"$OUT/test_elf64_image" "$OUT/steamos_ios_static_smoke.elf"
python3 - "$OUT/steamos_ios_static_smoke.elf" <<'PY'
import pathlib, sys
b = pathlib.Path(sys.argv[1]).read_bytes()
assert b.startswith(b"\x7fELF\x02\x01\x01")
assert b"STEAMOS_IOS_ELF_OK\n" in b
print("STEAMOS_IOS_ELF_FIXTURE_OK")
PY
