#!/usr/bin/env python3
from __future__ import annotations

import pathlib
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: apply-dxmt-stdlib-headers.py <DXMT checkout>")

root = pathlib.Path(sys.argv[1]).resolve()
path = root / "src/util/sha1/sha1_util.hpp"
text = path.read_text()

need = "#include <functional>\n#include <string_view>\n"
if need in text:
    print(f"DXMT_STDLIB_PATCH_OK already-applied={path}")
    raise SystemExit(0)

anchor = "#include <cstring>\n#include <string>\n"
if text.count(anchor) != 1:
    raise SystemExit("error: pinned DXMT sha1_util.hpp include block drifted")

text = text.replace(anchor, anchor + "#include <functional>\n#include <string_view>\n", 1)
path.write_text(text)
print(f"DXMT_STDLIB_PATCH_OK applied={path}")
