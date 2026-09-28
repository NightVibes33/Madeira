#!/bin/bash
set -euo pipefail

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$BUILD_DIR/../.." && pwd)"
WINE_SRC="$REPO_ROOT/wine"
WINE_BUILD="$WINE_SRC/build-macos"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
BASE_OBJ="$BUILD_DIR/base-obj"
OUT_OBJ="$BUILD_DIR/obj"
OUT_LIB="$OUT_OBJ/libwineserver.a"
SHIMS_DIR="$REPO_ROOT/build/ntdll-unix/shims"

if [[ ! -x "$WINE_SRC/configure" ]]; then
    echo "error: pinned Wine submodule is not materialized: $WINE_SRC" >&2
    exit 1
fi

if [[ ! -f "$WINE_BUILD/include/config.h" ]]; then
    echo "=== Configuring Wine host tree for generated headers ==="
    mkdir -p "$WINE_BUILD"
    (
        cd "$WINE_BUILD"
        ../configure --without-x --disable-tests
    )
fi

[[ -f "$WINE_BUILD/include/config.h" ]] || {
    echo "error: Wine configure did not produce $WINE_BUILD/include/config.h" >&2
    exit 1
}

rm -rf "$BASE_OBJ"
mkdir -p "$BASE_OBJ" "$OUT_OBJ"
rm -f "$OUT_LIB"

CC_FLAGS=(
    -arch arm64 -isysroot "$SDK" -miphoneos-version-min=17.0 -O2
    -I"$WINE_SRC/include" -I"$WINE_SRC/include/wine"
    -I"$WINE_BUILD/include"
    -I"$BUILD_DIR" -I"$WINE_SRC/server"
    -I"$SHIMS_DIR"
    -I"$BUILD_DIR/../madsync" -DHAVE_LINUX_NTSYNC_H=1
    -include "$BUILD_DIR/config_ios.h"
    -include stdarg.h
    -include "$BUILD_DIR/unicode_fix.h"
    -include "$BUILD_DIR/wineserver_ios_kill.h"
    -DBINDIR=\"/usr/local/bin\" -DDATADIR=\"/usr/local/share\"
    -D__WINESRC__ -DWINE_IOS=1
    -Dmain=wineserver_main
    -Wno-implicit-function-declaration
)

# These are the Wine server translation units that Madeira's build.sh does NOT
# replace with an iOS-specific or instrumented object. Keeping this list small
# is deliberate: build.sh remains the authority for patched/replaced objects.
BASE_SOURCES=(
    atom change clipboard completion console d3dkmt debugger device directory
    file hook mailslot mutex named_pipe procfs ptrace registry semaphore serial
    signal symlink timer token trace
)

echo "=== Building pristine Wine server objects for iOS ==="
for name in "${BASE_SOURCES[@]}"; do
    src="$WINE_SRC/server/$name.c"
    out="$BASE_OBJ/$name.o"
    err="$BASE_OBJ/$name.err"
    printf "  %-24s " "$name"
    if xcrun -sdk iphoneos clang "${CC_FLAGS[@]}" -c "$src" -o "$out" 2>"$err"; then
        echo "OK"
    else
        echo "FAILED"
        cat "$err"
        exit 1
    fi
done

ar rcs "$OUT_LIB" "$BASE_OBJ"/*.o
member_count="$(ar -t "$OUT_LIB" | grep -E '\\.o
[[ "$member_count" -eq "${#BASE_SOURCES[@]}" ]] || {
    echo "error: base archive member mismatch: got $member_count expected ${#BASE_SOURCES[@]}" >&2
    exit 1
}

echo "WINESERVER_BASE_OK members=$member_count archive=$OUT_LIB"
 | wc -l | tr -d ' ')"
[[ "$member_count" -eq "${#BASE_SOURCES[@]}" ]] || {
    echo "error: base archive member mismatch: got $member_count expected ${#BASE_SOURCES[@]}" >&2
    exit 1
}

echo "WINESERVER_BASE_OK members=$member_count archive=$OUT_LIB"
