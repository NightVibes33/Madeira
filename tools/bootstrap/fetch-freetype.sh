#!/bin/bash
set -euo pipefail
R="$(cd "$(dirname "\${BASH_SOURCE[0]}")/../.." && pwd)"
DEST="$R/research/freetype"
PIN="42608f77f20749dd6ddc9e0536788eaad70ea4b5"

if [[ -d "$DEST/.git" ]]; then
  ACTUAL="$(git -C "$DEST" rev-parse HEAD)"
  [[ "$ACTUAL" == "$PIN" ]] || {
    echo "ERROR: freetype drift actual=$ACTUAL expected=$PIN" >&2
    exit 1
  }
  echo "FREETYPE_OK cached=$PIN"
  exit 0
fi

rm -rf "$DEST"
git clone --filter=blob:none --no-checkout https://github.com/freetype/freetype.git "$DEST"
git -C "$DEST" fetch --depth 1 origin "$PIN"
git -C "$DEST" checkout --detach "$PIN"
ACTUAL="$(git -C "$DEST" rev-parse HEAD)"
[[ "$ACTUAL" == "$PIN" ]] || exit 1
echo "FREETYPE_OK pin=$ACTUAL"
