#!/bin/bash
# Configure (first time) and build the FEXCore static libraries the app links
# (FEX/build-ios/FEXCore/Source/*.a and External/*). Options mirror the
# development build's CMakeCache.
set -eu
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
B="$R/FEX/build-ios"
python3 "$R/tools/patches/apply-fex-ios-apple-runtime.py" "$R/FEX"
if [ ! -f "$B/CMakeCache.txt" ]; then
    cmake -S "$R/FEX" -B "$B" -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_SYSTEM_PROCESSOR=arm64 -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_TESTING=OFF -DBUILD_THUNKS=OFF -DBUILD_FEXCONFIG=OFF -DBUILD_FEX_LINUX_TESTS=OFF \
        -DENABLE_FEX_ALLOCATOR=OFF -DENABLE_ASSERTIONS=OFF -DENABLE_CLANG_THUNKS=ON -DENABLE_CCACHE=ON \
        -DTUNE_CPU=none
fi
# Madeira's Xcode target links all three upstream FEX archives. JemallocLibs
# remains required on Apple even when the Linux-specific allocators are disabled;
# in that configuration it is the allocator-hooks archive without rpmalloc/jemalloc.
cmake --build "$B" --target FEXCore FEXCore_Base JemallocLibs
test -s "$B/FEXCore/Source/libFEXCore.a"
test -s "$B/FEXCore/Source/libFEXCore_Base.a"
test -s "$B/FEXCore/Source/libJemallocLibs.a"
ls "$B/FEXCore/Source/"*.a
