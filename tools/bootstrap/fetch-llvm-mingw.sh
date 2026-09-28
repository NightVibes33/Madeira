#!/bin/bash
set -euo pipefail
R="$(cd "$(dirname "\${BASH_SOURCE[0]}")/../.." && pwd)"
DEST="$R/toolchains/llvm-mingw-20260421-ucrt-macos-universal"
URL="https://github.com/mstorsjo/llvm-mingw/releases/download/20260421/llvm-mingw-20260421-ucrt-macos-universal.tar.xz"
EXPECTED="bd85a3975723815cef28dbbd2ca2cb0c926f6b348a12a0453f39f7af273cb3f7"

if [[ -x "$DEST/bin/aarch64-w64-mingw32-clang" && -x "$DEST/bin/arm64ec-w64-mingw32-clang" ]]; then
  echo "LLVM_MINGW_OK cached=$DEST"
  exit 0
fi

mkdir -p "$R/toolchains"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl --fail --location --retry 3 "$URL" -o "$TMP/llvm-mingw.tar.xz"
ACTUAL="$(shasum -a 256 "$TMP/llvm-mingw.tar.xz" | awk '{print $1}')"
[[ "$ACTUAL" == "$EXPECTED" ]] || {
  echo "ERROR: llvm-mingw SHA-256 mismatch actual=$ACTUAL expected=$EXPECTED" >&2
  exit 1
}
tar -xJf "$TMP/llvm-mingw.tar.xz" -C "$R/toolchains"
[[ -x "$DEST/bin/aarch64-w64-mingw32-clang" ]] || {
  echo "ERROR: llvm-mingw extraction did not produce expected compiler" >&2
  exit 1
}
echo "LLVM_MINGW_OK sha256=$ACTUAL"
