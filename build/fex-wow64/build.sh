#!/bin/bash
# Configure (first time) and build FEX's aarch64 WOW64 module
# (libwow64fex.dll, shipped as xtajit.dll), used by Wine WoW64 for x86 guests.
set -eu

R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PATH="$R/toolchains/llvm-mingw-20260922-ucrt-macos-universal/bin:$PATH"

PATCH="$R/tools/patches/fex-llvm23-cstdlib.patch"
STRING_CONV="$R/FEX/FEXCore/Source/Common/StringConv.h"
if ! grep -q '^#include <cstdlib>' "$STRING_CONV"; then
    git -C "$R/FEX" apply "$PATCH"
fi

LOCK_PATCH="$R/tools/patches/fex-arm64ec-interval-lock.patch"
INVALIDATION_TRACKER="$R/FEX/Source/Windows/Common/InvalidationTracker.cpp"
if ! grep -q 'ml1140: NEVER call NtProtectVirtualMemory while holding' "$INVALIDATION_TRACKER"; then
    git -C "$R/FEX" apply "$LOCK_PATCH"
fi
grep -q '\[iOS-xlock\] ml1140' "$INVALIDATION_TRACKER" || {
    echo "error: FEX iOS interval-lock fix was not applied" >&2
    exit 1
}

B="$R/FEX/build-wow64"
if [ ! -f "$B/CMakeCache.txt" ]; then
    cmake -S "$R/FEX" -B "$B" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_TOOLCHAIN_FILE="$R/FEX/Data/CMake/toolchain_mingw.cmake" \
        -DMINGW_TRIPLE=aarch64-w64-mingw32 \
        -DFEX_IOS_HOST_BUILD=ON \
        -DCMAKE_DISABLE_FIND_PACKAGE_fmt=ON \
        -DCMAKE_C_FLAGS=-DFEX_IOS_HOST \
        -DCMAKE_CXX_FLAGS=-DFEX_IOS_HOST \
        -DCMAKE_ASM_FLAGS=-DFEX_IOS_HOST \
        -DENABLE_LTO=OFF \
        -DENABLE_ASSERTIONS=OFF \
        -DENABLE_JEMALLOC_GLIBC_ALLOC=OFF \
        -DBUILD_TESTING=OFF \
        -DBUILD_FEXCONFIG=OFF \
        -DTUNE_ARCH=generic \
        -DTUNE_CPU=none \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
fi

cmake --build "$B" --target wow64fex
cp "$B/Bin/libwow64fex.dll" "$R/app/Madeira/aarch64-windows/xtajit.dll"
ls -l "$R/app/Madeira/aarch64-windows/xtajit.dll"
