#!/bin/bash
set -euo pipefail
R="$(cd "$(dirname "\${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$R/toolchains/llvm-project"
HOST="$R/toolchains/llvm-host-build"
IOS="$R/toolchains/llvm-ios-build"
PIN="8dfdcc7b7bf66834a761bd8de445840ef68e4d1a"

if compgen -G "$IOS/lib/*.a" >/dev/null && [[ -x "$HOST/bin/llvm-tblgen" ]]; then
  echo "LLVM_IOS_OK cached=$IOS"
  exit 0
fi

mkdir -p "$R/toolchains"
if [[ ! -d "$SRC/.git" ]]; then
  git clone --filter=blob:none --no-checkout https://github.com/llvm/llvm-project.git "$SRC"
fi
git -C "$SRC" fetch --depth 1 origin "$PIN"
git -C "$SRC" checkout --detach "$PIN"
[[ "$(git -C "$SRC" rev-parse HEAD)" == "$PIN" ]] || exit 1

ADDLLVM="$SRC/llvm/cmake/modules/AddLLVM.cmake"
if ! grep -q 'Darwin|iOS' "$ADDLLVM"; then
  python3 - "$ADDLLVM" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
old = 'MATCHES "Darwin"'
if old not in s:
    raise SystemExit("AddLLVM.cmake Darwin match not found")
p.write_text(s.replace(old, 'MATCHES "Darwin|iOS"', 1))
PY
fi

cmake -S "$SRC/llvm" -B "$HOST" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_ENABLE_PROJECTS= \
  -DLLVM_TARGETS_TO_BUILD= \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_ENABLE_ZLIB=OFF
cmake --build "$HOST" --target llvm-tblgen --parallel 3

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
cmake -S "$SRC/llvm" -B "$IOS" -G Ninja \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_SYSROOT="$SDK" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_HOST_TRIPLE=arm64-apple-ios17.0 \
  -DLLVM_DEFAULT_TARGET_TRIPLE=arm64-apple-ios17.0 \
  -DLLVM_TARGET_ARCH=host \
  -DLLVM_TARGETS_TO_BUILD= \
  -DLLVM_ENABLE_PROJECTS= \
  -DLLVM_TABLEGEN="$HOST/bin/llvm-tblgen" \
  -DLLVM_BUILD_TOOLS=OFF \
  -DLLVM_BUILD_UTILS=OFF \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_ENABLE_ZLIB=OFF
cmake --build "$IOS" --parallel 3
compgen -G "$IOS/lib/*.a" >/dev/null || {
  echo "ERROR: iOS LLVM build produced no static archives" >&2
  exit 1
}
echo "LLVM_IOS_OK pin=$PIN archives=$(find "$IOS/lib" -name '*.a' | wc -l | tr -d ' ')"
