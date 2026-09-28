#!/bin/bash
set -euo pipefail
R="$(cd "$(dirname "\${BASH_SOURCE[0]}")/../.." && pwd)"
W="$R/wine"
B="$W/build-macos"
TC="$R/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin"

[[ -x "$TC/aarch64-w64-mingw32-clang" ]] || {
  echo "ERROR: llvm-mingw missing; run tools/bootstrap/fetch-llvm-mingw.sh" >&2
  exit 1
}

export PATH="$TC:/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:$PATH"
if [[ ! -f "$B/config.status" ]]; then
  mkdir -p "$B"
  (
    cd "$B"
    ../configure \
      --without-x \
      --without-vulkan \
      --without-freetype \
      --without-gnutls \
      --without-gstreamer \
      --without-cups \
      --disable-tests
  )
fi

[[ -f "$B/include/config.h" ]] || {
  echo "ERROR: Wine configure did not generate include/config.h" >&2
  exit 1
}

make -C "$B" -j3 tools/winebuild/winebuild tools/widl/widl
echo "WINE_GENERATED_OK build=$B"
