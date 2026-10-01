#!/bin/bash
# Configure (first time) and build the ARM64EC FEX module
# (libarm64ecfex.dll, shipped as xtajit64.dll).
#
# FEX_IOS_HOST_BUILD and FEX_IOS_HOST are mandatory: the Windows translator's
# iOS JIT alias/WriteOffset path is guarded by these settings.
# LLVM 23.1.2 is required because its ARM64EC driver can use llvm-mingw's
# native aarch64 sysroot for the hybrid ARM64X libc++ runtime.
set -eu

R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PATH="$R/toolchains/llvm-mingw-20260922-ucrt-macos-universal/bin:$PATH"

PATCH="$R/tools/patches/fex-llvm23-cstdlib.patch"
STRING_CONV="$R/FEX/FEXCore/Source/Common/StringConv.h"
if ! grep -q '^#include <cstdlib>' "$STRING_CONV"; then
    git -C "$R/FEX" apply "$PATCH"
fi

INVALIDATION_HEADER="$R/FEX/Source/Windows/Common/InvalidationTracker.h"
INVALIDATION_TRACKER="$R/FEX/Source/Windows/Common/InvalidationTracker.cpp"
python3 "$R/tools/patches/apply-fex-interval-mutex.py" "$INVALIDATION_HEADER"
python3 "$R/tools/patches/apply-fex-invalidation-lock.py" "$INVALIDATION_TRACKER"
grep -q 'WritePriorityMutex::Mutex IntervalsLock' "$INVALIDATION_HEADER" || {
    echo "error: FEX iOS interval mutex fix was not applied" >&2
    exit 1
}
grep -q '\[iOS-xlock\] ml1140' "$INVALIDATION_TRACKER" || {
    echo "error: FEX iOS interval-lock fix was not applied" >&2
    exit 1
}

SYNC_CPP="$R/FEX/Source/Windows/Common/WinAPI/Sync.cpp"
python3 "$R/tools/patches/apply-fex-jit-sync-alias.py" "$SYNC_CPP"
grep -q 'SteamIOS ml1144' "$SYNC_CPP" || {
    echo "error: FEX iOS JIT sync-alias fix was not applied" >&2
    exit 1
}

B="$R/FEX/build-arm64ec"
if [ ! -f "$B/CMakeCache.txt" ]; then
    cmake -S "$R/FEX" -B "$B" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_TOOLCHAIN_FILE="$R/FEX/Data/CMake/toolchain_mingw.cmake" \
        -DMINGW_TRIPLE=arm64ec-w64-mingw32 \
        -DFEX_IOS_HOST_BUILD=ON \
        -DCMAKE_DISABLE_FIND_PACKAGE_fmt=ON \
        -DTUNE_ARCH=generic -DTUNE_CPU=none \
        -DCMAKE_C_FLAGS=-DFEX_IOS_HOST \
        -DCMAKE_CXX_FLAGS=-DFEX_IOS_HOST \
        -DCMAKE_ASM_FLAGS=-DFEX_IOS_HOST \
        -DENABLE_LTO=OFF \
        -DENABLE_FEX_ALLOCATOR=ON \
        -DENABLE_JEMALLOC_GLIBC_ALLOC=ON \
        -DENABLE_OFFLINE_RUNTIME=ON \
        -DBUILD_FEXCONFIG=ON \
        -DENABLE_CLANG_THUNKS=ON \
        -DENABLE_CCACHE=ON \
        -DBUILD_TESTING=OFF \
        -DBUILD_THUNKS=OFF \
        -DENABLE_ASSERTIONS=OFF
fi

cmake --build "$B" --target arm64ecfex
# Hangover-compatible canonical CPU-module name plus the legacy Madeira alias.
# Both are intentionally byte-identical; Wine selects the canonical name through
# HODLL64 while the alias keeps old prefixes and diagnostics compatible.
cp "$B/Bin/libarm64ecfex.dll" "$R/app/Madeira/arm64ec-windows/libarm64ecfex.dll"
cp "$R/app/Madeira/arm64ec-windows/libarm64ecfex.dll" "$R/app/Madeira/arm64ec-windows/xtajit64.dll"
cmp "$R/app/Madeira/arm64ec-windows/libarm64ecfex.dll" "$R/app/Madeira/arm64ec-windows/xtajit64.dll"
echo "STEAMOS_HANGOVER_FEX64_OK"
ls -l "$R/app/Madeira/arm64ec-windows/libarm64ecfex.dll" "$R/app/Madeira/arm64ec-windows/xtajit64.dll"
