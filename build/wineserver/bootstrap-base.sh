#!/bin/bash
set -euo pipefail
BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$BUILD_DIR/../.." && pwd)"
WINE_SRC="$REPO_ROOT/wine"
WINE_BUILD="$WINE_SRC/build-macos"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
OBJ_DIR="$BUILD_DIR/base-obj"
OUT="$BUILD_DIR/obj/libwineserver.a"
SHIMS_DIR="$REPO_ROOT/build/ntdll-unix/shims"

[[ -f "$WINE_BUILD/include/config.h" ]] || {
  echo "ERROR: $WINE_BUILD/include/config.h missing; run build/wine-unix/bootstrap-generated.sh" >&2
  exit 1
}

rm -rf "$OBJ_DIR"
mkdir -p "$OBJ_DIR" "$(dirname "$OUT")"

SOURCES=(
  async atom change class clipboard completion console d3dkmt debugger device
  directory event fd file handle hook inproc_sync mach mailslot main mapping mutex
  named_pipe object process procfs ptrace queue region registry request semaphore
  serial signal sock symlink thread timer token trace unicode user window winstation
)

FLAGS=(
  -arch arm64 -isysroot "$SDK" -miphoneos-version-min=17.0 -O2
  -I"$WINE_SRC/include" -I"$WINE_SRC/include/wine"
  -I"$WINE_BUILD/include" -I"$BUILD_DIR" -I"$WINE_SRC/server"
  -I"$SHIMS_DIR" -I"$BUILD_DIR/../madsync"
  -include "$BUILD_DIR/config_ios.h"
  -include stdarg.h
  -DBINDIR=\"/usr/local/bin\" -DDATADIR=\"/usr/local/share\"
  -D__WINESRC__ -DWINE_IOS=1 -DHAVE_LINUX_NTSYNC_H=1
  -Dmain=wineserver_main
  -Wno-implicit-function-declaration
)

for name in "\${SOURCES[@]}"; do
  src="$WINE_SRC/server/$name.c"
  [[ -f "$src" ]] || { echo "ERROR: missing Wine server source $src" >&2; exit 1; }
  echo "  base wineserver: $name.c"
  xcrun -sdk iphoneos clang "\${FLAGS[@]}" -c "$src" -o "$OBJ_DIR/$name.o"
done

xcrun -sdk iphoneos ar rcs "$OUT" "$OBJ_DIR"/*.o
xcrun -sdk iphoneos ranlib "$OUT"
echo "WINESERVER_BASE_OK path=$OUT bytes=$(wc -c < "$OUT" | tr -d ' ')"
