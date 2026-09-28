#!/usr/bin/env python3
"""Fail closed if the SteamOS-iOS foundation drifts from its frozen Madeira pins."""
from __future__ import annotations

import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
EXPECTED = {
    ".": "9e8291eb42519b35b3d40b5f915c3a5f6d4fff45",
    "FEX": "2838f3be52437620348264ada6c41042a9085290",
    "wine": "8e3d23c77ceb903b59fdd8c123c867b7591490d5",
    "research/dxmt": "a5e0cd3d41bf248fd1c030a2e1c515ba3522f4ef",
    "FEX/External/rpmalloc": "812c2b9cf4310ffacf14e6b64066e78ab0c394b5",
}


def rev(path: str) -> str:
    cwd = ROOT if path == "." else ROOT / path
    return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=cwd, text=True).strip()


def main() -> int:
    failed = False
    for path, expected in EXPECTED.items():
        try:
            actual = rev(path)
        except Exception as exc:
            print(f"PIN_MISSING path={path} error={exc}", file=sys.stderr)
            failed = True
            continue
        status = "OK" if actual == expected else "DRIFT"
        print(f"PIN_{status} path={path} actual={actual} expected={expected}")
        failed |= actual != expected
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
