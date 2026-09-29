#!/usr/bin/env python3
from __future__ import annotations

import pathlib
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: apply-dxmt-ios-xcode27.py <DXMT checkout>")

root = pathlib.Path(sys.argv[1]).resolve()
path = root / "src/airconv/shaders/air_tessellation.metal"
text = path.read_text()

old = """  return __metal_atomic_fetch_add_explicit(out_count, 1, int(memory_order_relaxed), __METAL_MEMORY_SCOPE_THREADGROUP__);
"""
new = """  return __metal_atomic_fetch_add_explicit(out_count, 1, int(memory_order_relaxed), __METAL_MEMORY_SCOPE_THREADGROUP__, __METAL_MEMORY_FLAGS_NONE__);
"""

if new in text:
    print(f"DXMT_XCODE27_PATCH_OK already-applied={path}")
    raise SystemExit(0)

count = text.count(old)
if count != 1:
    raise SystemExit(
        f"error: pinned DXMT tessellation intrinsic drift: expected one exact call, found {count}"
    )

path.write_text(text.replace(old, new, 1))
print(f"DXMT_XCODE27_PATCH_OK applied={path}")
