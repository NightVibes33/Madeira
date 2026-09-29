#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEST="$ROOT/toolchains/llvm-project"
REPO="https://github.com/llvm/llvm-project.git"
PIN="8dfdcc7b7bf66834a761bd8de445840ef68e4d1a"

if [[ -d "$DEST/.git" ]]; then
    actual="$(git -C "$DEST" rev-parse HEAD 2>/dev/null || true)"
    if [[ "$actual" == "$PIN" ]]; then
        echo "LLVM_PROJECT_OK cached=$DEST commit=$actual"
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
    echo "error: llvm-project pin mismatch: got $actual expected $PIN" >&2
    exit 1
}
echo "LLVM_PROJECT_OK commit=$actual path=$DEST"
