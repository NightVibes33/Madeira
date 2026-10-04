#!/usr/bin/env python3
from __future__ import annotations

import pathlib
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: apply-dxmt-stdlib-headers.py <DXMT checkout>")

root = pathlib.Path(sys.argv[1]).resolve()

def ensure_include(path: pathlib.Path, anchor: str, include: str, label: str) -> None:
    text = path.read_text()
    if include in text:
        print(f"DXMT_STDLIB_PATCH_OK already-applied={label} path={path}")
        return
    if text.count(anchor) != 1:
        raise SystemExit(f"error: pinned DXMT {label} include block drifted")
    path.write_text(text.replace(anchor, anchor + include, 1))
    print(f"DXMT_STDLIB_PATCH_OK applied={label} path={path}")

sha1 = root / "src/util/sha1/sha1_util.hpp"
ensure_include(sha1, "#include <cstring>\n", "#include <functional>\n", "sha1-functional")
ensure_include(sha1, "#include <string>\n", "#include <string_view>\n", "sha1-string-view")

ftl = root / "include/ftl.hpp"
ensure_include(ftl, "#include <algorithm>\n", "#include <iterator>\n", "ftl-iterator")
