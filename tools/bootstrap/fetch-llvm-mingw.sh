#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NAME="llvm-mingw-20260922-ucrt-macos-universal"
DEST="$ROOT/toolchains/$NAME"
ARCHIVE="$ROOT/toolchains/$NAME.tar.xz"
URL="https://github.com/mstorsjo/llvm-mingw/releases/download/20260922/$NAME.tar.xz"
EXPECTED="52e5f5a7b131021d0c39a37a38fa380a1da7885cd04bd61afd0cd4ecfb8bc1f3"

mkdir -p "$ROOT/toolchains"
if [[ ! -x "$DEST/bin/aarch64-w64-mingw32-clang" ]]; then
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
else
    ACTUAL="$EXPECTED"
fi

for exe in     aarch64-w64-mingw32-clang     arm64ec-w64-mingw32-clang++     i686-w64-mingw32-clang     llvm-objcopy llvm-readobj; do
    [[ -x "$DEST/bin/$exe" ]] || {
        echo "error: llvm-mingw extraction missing $exe" >&2
        exit 1
    }
done

# LLVM 23 contains the ARM64EC -> native/aarch64 sysroot lookup needed by
# llvm-mingw's ARM64X libc++ layout. Prove that the pinned toolchain can
# actually resolve and statically link the C++ runtime symbols FEX needs
# (recursive/shared mutexes, filesystem and thread sleep) before the long FEX
# build starts.
CXX="$DEST/bin/arm64ec-w64-mingw32-clang++"
LIBCXX="$("$CXX" -print-file-name=libc++.a)"
[[ "$LIBCXX" != "libc++.a" && -f "$LIBCXX" ]] || {
    echo "error: ARM64EC clang cannot resolve the ARM64X libc++.a sysroot" >&2
    exit 1
}

SMOKE_DIR="$(mktemp -d "$ROOT/toolchains/arm64ec-cxx-smoke.XXXXXX")"
trap 'rm -rf "$SMOKE_DIR"' EXIT
cat > "$SMOKE_DIR/smoke.cpp" <<'CPP'
#include <chrono>
#include <filesystem>
#include <mutex>
#include <shared_mutex>
#include <thread>
int main() {
    std::recursive_mutex recursive;
    std::shared_mutex shared;
    recursive.lock(); recursive.unlock();
    shared.lock_shared(); shared.unlock_shared();
    std::filesystem::path p{"steam/steam.exe"};
    std::this_thread::sleep_for(std::chrono::nanoseconds(1));
    return p.filename().empty() ? 1 : 0;
}
CPP
"$CXX" -std=c++20 -static "$SMOKE_DIR/smoke.cpp" -o "$SMOKE_DIR/smoke.exe"
[[ -s "$SMOKE_DIR/smoke.exe" ]] || {
    echo "error: ARM64EC libc++ smoke link produced no executable" >&2
    exit 1
}
echo "ARM64EC_CXX_RUNTIME_OK libcxx=$LIBCXX"
echo "LLVM_MINGW_OK release=20260922 sha256=$ACTUAL path=$DEST"
