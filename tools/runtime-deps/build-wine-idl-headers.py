#!/usr/bin/env python3
"""Generate Wine headers for an IDL import closure in an out-of-tree build."""

from __future__ import annotations

import pathlib
import re
import subprocess
import sys

IMPORT_RE = re.compile(r'^\s*import\s+"([^"]+)"\s*;', re.MULTILINE)


def fail(message: str) -> "NoReturn":
    raise SystemExit(f"error: {message}")


if len(sys.argv) < 4:
    fail("usage: build-wine-idl-headers.py <wine-source> <wine-build> <root.idl> [...]")

source = pathlib.Path(sys.argv[1]).resolve()
build = pathlib.Path(sys.argv[2]).resolve()
include = source / "include"

if not (source / "configure").is_file():
    fail(f"not a Wine source tree: {source}")
if not (build / "config.status").is_file():
    fail(f"Wine build is not configured: {build}")

roots = sys.argv[3:]
seen: set[str] = set()
visiting: set[str] = set()
order: list[str] = []


def visit(name: str) -> None:
    if name in seen:
        return
    if name in visiting:
        # Wine's generated SDK headers have intentional dependency cycles
        # (for example d3d10 <-> dxgi/sdk-layer families). The source generator
        # can emit either side without the peer header existing yet, so keep
        # the node in the closure and let one make invocation build the set.
        return
    if not name.endswith(".idl"):
        return

    path = include / name
    if not path.is_file():
        fail(f"imported IDL is missing from pinned Wine source: {name}")

    visiting.add(name)
    text = path.read_text(errors="strict")
    for dep in IMPORT_RE.findall(text):
        if dep.endswith(".idl"):
            visit(dep)

    # WIDL sources can emit extra generated-header dependencies through
    # cpp_quote("#include \\"foo.h\\""). Parse this exact source syntax
    # without a regex so escaped quote handling cannot drift.
    cpp_marker = 'cpp_quote("#include \\"'
    for line in text.splitlines():
        start = line.find(cpp_marker)
        if start < 0:
            continue
        start += len(cpp_marker)
        end = line.find('\\"', start)
        if end <= start:
            fail(f"malformed cpp_quote include in {name}: {line}")
        header = line[start:end]
        candidate = str(pathlib.PurePosixPath(header).with_suffix(".idl"))
        if (include / candidate).is_file():
            visit(candidate)
    visiting.remove(name)
    seen.add(name)
    order.append(name)


for root in roots:
    visit(root)

targets = [f"include/{pathlib.PurePosixPath(name).with_suffix('.h')}" for name in order]
if not targets:
    fail("no generated header targets discovered")

print("WINE_IDL_HEADER_CLOSURE count=%d" % len(targets))
for target in targets:
    print("  " + target)

subprocess.run(["make", *targets], cwd=build, check=True)

missing = [target for target in targets if not (build / target).is_file()]
if missing:
    fail("make returned success but generated headers are missing: " + ", ".join(missing))

print("WINE_IDL_HEADERS_OK count=%d roots=%s" % (len(targets), ",".join(roots)))
