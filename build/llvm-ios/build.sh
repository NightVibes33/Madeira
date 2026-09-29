#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/toolchains/llvm-project/llvm"
HOST="$ROOT/toolchains/llvm-host-build"
IOS="$ROOT/toolchains/llvm-ios-build"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

[[ -f "$SRC/CMakeLists.txt" ]] || {
    echo "error: llvm-project is not materialized; run tools/runtime-deps/fetch-llvm-project.sh" >&2
    exit 1
}
command -v cmake >/dev/null
command -v ninja >/dev/null

if [[ ! -x "$HOST/bin/llvm-tblgen" ]]; then
    echo "=== Configuring host llvm-tblgen ==="
    cmake -S "$SRC" -B "$HOST" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLVM_TARGETS_TO_BUILD=Native \
        -DLLVM_ENABLE_PROJECTS= \
        -DLLVM_BUILD_TOOLS=ON \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_BENCHMARKS=OFF \
        -DLLVM_INCLUDE_EXAMPLES=OFF \
        -DLLVM_ENABLE_BINDINGS=OFF \
        -DLLVM_ENABLE_ZLIB=OFF \
        -DLLVM_ENABLE_ZSTD=OFF \
        -DLLVM_ENABLE_TERMINFO=OFF \
        -DLLVM_ENABLE_LIBXML2=OFF
    cmake --build "$HOST" --target llvm-tblgen -j "$JOBS"
fi

[[ -x "$HOST/bin/llvm-tblgen" ]] || {
    echo "error: host llvm-tblgen was not produced" >&2
    exit 1
}

if [[ ! -f "$IOS/CMakeCache.txt" ]]; then
    echo "=== Configuring LLVM static libraries for iOS arm64 ==="
    cmake -S "$SRC" -B "$IOS" -G Ninja \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_SYSROOT="$SDK" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
        -DLLVM_TABLEGEN="$HOST/bin/llvm-tblgen" \
        -DLLVM_HOST_TRIPLE=arm64-apple-ios17.0 \
        -DLLVM_DEFAULT_TARGET_TRIPLE=arm64-apple-ios17.0 \
        -DLLVM_TARGET_ARCH=host \
        -DLLVM_TARGETS_TO_BUILD= \
        -DLLVM_ENABLE_PROJECTS= \
        -DLLVM_BUILD_TOOLS=OFF \
        -DLLVM_INCLUDE_TOOLS=OFF \
        -DLLVM_BUILD_UTILS=OFF \
        -DLLVM_INCLUDE_UTILS=OFF \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_BENCHMARKS=OFF \
        -DLLVM_INCLUDE_EXAMPLES=OFF \
        -DLLVM_ENABLE_BINDINGS=OFF \
        -DLLVM_ENABLE_ZLIB=OFF \
        -DLLVM_ENABLE_ZSTD=OFF \
        -DLLVM_ENABLE_TERMINFO=OFF \
        -DLLVM_ENABLE_LIBXML2=OFF \
        -DLLVM_BUILD_LLVM_DYLIB=OFF \
        -DLLVM_LINK_LLVM_DYLIB=OFF
fi

echo "=== Building LLVM iOS static libraries only ==="
cmake --build "$IOS" --target llvm-libraries -j "$JOBS"

required=(
    libLLVMCore.a
    libLLVMIRReader.a
    libLLVMBitReader.a
    libLLVMBitWriter.a
    libLLVMSupport.a
)
for lib in "${required[@]}"; do
    [[ -s "$IOS/lib/$lib" ]] || {
        echo "error: missing required iOS LLVM archive $IOS/lib/$lib" >&2
        exit 1
    }
    lipo -info "$IOS/lib/$lib"
done

count="$(find "$IOS/lib" -maxdepth 1 -name '*.a' -type f | wc -l | tr -d ' ')"
[[ "$count" -ge 5 ]] || {
    echo "error: expected LLVM static archive set, found only $count" >&2
    exit 1
}
echo "LLVM_IOS_CLEAN_BUILD_OK archives=$count commit=$(git -C "$ROOT/toolchains/llvm-project" rev-parse HEAD)"
