#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEST="$ROOT/research/freetype"
REPO="https://github.com/freetype/freetype.git"
PIN="42608f77f20749dd6ddc9e0536788eaad70ea4b5"
TAG="VER-2-13-3"

if [[ -d "$DEST/.git" ]]; then
    actual="$(git -C "$DEST" rev-parse HEAD 2>/dev/null || true)"
    if [[ "$actual" == "$PIN" ]]; then
        echo "FREETYPE_OK cached=$DEST commit=$actual"
        exit 0
    fi
fi

rm -rf "$DEST"
mkdir -p "$DEST"
git -C "$DEST" init -q
git -C "$DEST" remote add origin "$REPO"
git -C "$DEST" fetch --depth 1 origin "$PIN"
git -C "$DEST" checkout -q --detach "$PIN"
actual="$(git -C "$DEST" rev-parse HEAD)"
[[ "$actual" == "$PIN" ]] || {
    echo "error: FreeType pin mismatch: got $actual expected $PIN" >&2
    exit 1
}

echo "FREETYPE_OK tag=$TAG commit=$actual path=$DEST"
