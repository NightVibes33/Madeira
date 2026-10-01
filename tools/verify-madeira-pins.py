#!/usr/bin/env python3
"""Fail closed if the SteamOS-iOS foundation drifts from its frozen Madeira pins.

The fast CI gate intentionally does not clone the very large recursive submodules.
It verifies the superproject gitlinks directly. If FEX is already materialized
(e.g. in a full build), the nested rpmalloc pin is verified too.
"""
from __future__ import annotations

import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
BASELINE = "9e8291eb42519b35b3d40b5f915c3a5f6d4fff45"
EXPECTED_GITLINKS = {
    "FEX": "26859e184ad90f0e811d7f8bbd943a4b1573a2c3",
    "wine": "4f5b19718f4de88ecc5cb0dc08b119497a67ba8f",
    "research/dxmt": "a5e0cd3d41bf248fd1c030a2e1c515ba3522f4ef",
}
EXPECTED_RPMALLOC = "812c2b9cf4310ffacf14e6b64066e78ab0c394b5"


def gitlink(path: str) -> str:
    line = subprocess.check_output(
        ["git", "ls-tree", "HEAD", "--", path],
        cwd=ROOT,
        text=True,
    ).strip()
    if not line:
        raise RuntimeError(f"missing gitlink: {path}")
    meta, returned_path = line.split("\t", 1)
    mode, kind, sha = meta.split()
    if returned_path != path or mode != "160000" or kind != "commit":
        raise RuntimeError(
            f"{path} is not a submodule gitlink: mode={mode} type={kind} path={returned_path}"
        )
    return sha


def materialized_rev(path: pathlib.Path) -> str | None:
    if not path.exists():
        return None
    probe = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=path,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return probe.stdout.strip() if probe.returncode == 0 else None


def main() -> int:
    failed = False
    ancestor = subprocess.run(
        ["git", "merge-base", "--is-ancestor", BASELINE, "HEAD"],
        cwd=ROOT,
        check=False,
    ).returncode == 0
    print(f"BASELINE_{'OK' if ancestor else 'DRIFT'} ancestor={BASELINE}")
    failed |= not ancestor

    for path, expected in EXPECTED_GITLINKS.items():
        try:
            actual = gitlink(path)
        except Exception as exc:
            print(f"PIN_MISSING path={path} error={exc}", file=sys.stderr)
            failed = True
            continue
        status = "OK" if actual == expected else "DRIFT"
        print(f"PIN_{status} path={path} actual={actual} expected={expected}")
        failed |= actual != expected

    rpmalloc_path = ROOT / "FEX" / "External" / "rpmalloc"
    rpmalloc_actual = materialized_rev(rpmalloc_path)
    if rpmalloc_actual is None:
        print(
            "PIN_DEFERRED path=FEX/External/rpmalloc "
            f"expected={EXPECTED_RPMALLOC} reason=FEX-not-materialized"
        )
    else:
        status = "OK" if rpmalloc_actual == EXPECTED_RPMALLOC else "DRIFT"
        print(
            f"PIN_{status} path=FEX/External/rpmalloc "
            f"actual={rpmalloc_actual} expected={EXPECTED_RPMALLOC}"
        )
        failed |= rpmalloc_actual != EXPECTED_RPMALLOC

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
