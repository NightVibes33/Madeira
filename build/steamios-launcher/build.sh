#!/bin/bash
set -euo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CC="$R/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin/aarch64-w64-mingw32-clang"
SRC="$R/build/steamios-launcher/steamios-launcher.c"
OUT="$R/app/Madeira/aarch64-windows/steamios-launcher.exe"
test -x "$CC" || { echo "error: missing llvm-mingw AArch64 compiler: $CC" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"
"$CC" -Os -municode -mwindows -DUNICODE -D_UNICODE "$SRC" -o "$OUT"
test -s "$OUT"
echo "STEAMOS_IOS_WINDOWLESS_LAUNCHER_OK $(wc -c < "$OUT" | tr -d ' ') bytes"
