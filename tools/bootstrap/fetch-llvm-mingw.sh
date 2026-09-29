#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NAME="llvm-mingw-20260421-ucrt-macos-universal"
DEST="$ROOT/toolchains/$NAME"
ARCHIVE="$ROOT/toolchains/$NAME.tar.xz"
URL="https://github.com/mstorsjo/llvm-mingw/releases/download/20260421/$NAME.tar.xz"
EXPECTED="bd85a3975723815cef28dbbd2ca2cb0c926f6b348a12a0453f39f7af273cb3f7"

if [[ -x "$DEST/bin/aarch64-w64-mingw32-clang" ]]; then
    echo "LLVM_MINGW_OK cached=$DEST"
    exit 0
fi

mkdir -p "$ROOT/toolchains"
if [[ ! -f "$ARCHIVE" ]]; then
    curl --fail --location --retry 3 --output "$ARCHIVE" "$URL"
fi

if command -v shasum >/dev/null 2>&1; then
    ACTUAL="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
else
    ACTUAL="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
fi
if [[ "$ACTUAL" != "$EXPECTED" ]]; then
    echo "error: llvm-mingw SHA-256 mismatch: got $ACTUAL expected $EXPECTED" >&2
    rm -f "$ARCHIVE"
    exit 1
fi

rm -rf "$DEST"
tar -xJf "$ARCHIVE" -C "$ROOT/toolchains"
[[ -x "$DEST/bin/aarch64-w64-mingw32-clang" ]] || {
    echo "error: llvm-mingw extraction missing aarch64-w64-mingw32-clang" >&2
    exit 1
}
[[ -x "$DEST/bin/llvm-objcopy" ]] || {
    echo "error: llvm-mingw extraction missing llvm-objcopy" >&2
    exit 1
}

echo "LLVM_MINGW_OK sha256=$ACTUAL path=$DEST"
