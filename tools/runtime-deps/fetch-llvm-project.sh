#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEST="$ROOT/toolchains/llvm-project"
REPO="https://github.com/llvm/llvm-project.git"
PIN="8dfdcc7b7bf66834a761bd8de445840ef68e4d1a"
MAX_ATTEMPTS=5

if [[ -d "$DEST/.git" ]]; then
    actual="$(git -C "$DEST" rev-parse HEAD 2>/dev/null || true)"
    if [[ "$actual" == "$PIN" ]]; then
        echo "LLVM_PROJECT_OK cached=$DEST commit=$actual"
        exit 0
    fi
fi

# llvm-project is a large shallow fetch. Hosted runners occasionally reset the
# HTTP connection mid-pack (curl 56 / early EOF). Recreate the shallow repo and
# retry deterministically instead of turning a transient GitHub transport reset
# into a failed IPA build.
for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
    rm -rf "$DEST"
    mkdir -p "$DEST"
    git -C "$DEST" init -q
    git -C "$DEST" remote add origin "$REPO"
    git -C "$DEST" config http.version HTTP/1.1
    git -C "$DEST" config http.lowSpeedLimit 1000
    git -C "$DEST" config http.lowSpeedTime 60

    echo "LLVM_PROJECT_FETCH attempt=$attempt/$MAX_ATTEMPTS pin=$PIN"
    if git -C "$DEST" fetch --no-tags --depth 1 origin "$PIN" &&
       git -C "$DEST" checkout -q --detach "$PIN"; then
        actual="$(git -C "$DEST" rev-parse HEAD)"
        if [[ "$actual" == "$PIN" ]]; then
            echo "LLVM_PROJECT_OK commit=$actual path=$DEST attempt=$attempt"
            exit 0
        fi
    fi

    echo "warning: llvm-project fetch attempt $attempt failed; retrying" >&2
    sleep $((attempt * 2))
done

echo "error: unable to materialize llvm-project pin $PIN after $MAX_ATTEMPTS attempts" >&2
exit 1
