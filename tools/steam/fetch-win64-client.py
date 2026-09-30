#!/usr/bin/env python3
"""Fetch and assemble Valve's current Windows Steam client for SteamIOS.

The official steam_client_win64 manifest names every package needed by the
stable Windows client and supplies SHA-256 hashes. Packages are cached by their
content-addressed filenames, verified, and merged into one ready-to-run Steam
folder. No Windows installer is executed on-device.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import shutil
import sys
import time
import urllib.error
import urllib.request
import zipfile

MANIFEST_URL = "https://client-update.fastly.steamstatic.com/steam_client_win64"
PACKAGE_BASES = (
    "https://client-update.fastly.steamstatic.com/",
    "https://cdn.steamstatic.com/client/",
)
UA = "SteamIOS-CI/1.0"


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def download(url: str, attempts: int = 4) -> bytes:
    last: Exception | None = None
    for attempt in range(1, attempts + 1):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=90) as r:
                return r.read()
        except Exception as exc:
            last = exc
            if attempt != attempts:
                time.sleep(min(attempt * 2, 6))
    raise RuntimeError(f"download failed after {attempts} attempts: {url}: {last}")


def get_manifest(path: pathlib.Path | None) -> bytes:
    if path and path.is_file():
        data = path.read_bytes()
        if b'"win64"' not in data or b'"version"' not in data:
            raise RuntimeError(f"invalid Steam Win64 manifest: {path}")
        return data
    return download(MANIFEST_URL)


TOKEN_RE = re.compile(r'"((?:\\.|[^"\\])*)"|([{}])')


def _unescape(s: str) -> str:
    return s.replace(r"\\", "\").replace(r'\"', '"')


def parse_vdf(data: bytes) -> dict[str, object]:
    text = data.decode("utf-8", errors="strict")
    tokens: list[str] = []
    for m in TOKEN_RE.finditer(text):
        tokens.append(m.group(2) if m.group(2) else _unescape(m.group(1)))

    def parse_object(i: int, stop_on_brace: bool) -> tuple[dict[str, object], int]:
        out: dict[str, object] = {}
        while i < len(tokens):
            tok = tokens[i]
            if tok == "}":
                if not stop_on_brace:
                    raise RuntimeError("unexpected } in VDF")
                return out, i + 1
            if tok == "{":
                raise RuntimeError("unexpected { in VDF")
            key = tok
            i += 1
            if i >= len(tokens):
                raise RuntimeError(f"missing value for VDF key {key!r}")
            if tokens[i] == "{":
                value, i = parse_object(i + 1, True)
            else:
                if tokens[i] == "}":
                    raise RuntimeError(f"missing scalar for VDF key {key!r}")
                value = tokens[i]
                i += 1
            out[key] = value
        if stop_on_brace:
            raise RuntimeError("unterminated VDF object")
        return out, i

    parsed, end = parse_object(0, False)
    if end != len(tokens):
        raise RuntimeError("VDF parser did not consume all tokens")
    return parsed


def select_packages(parsed: dict[str, object]) -> tuple[str, list[tuple[str, str, str, int]]]:
    win = parsed.get("win64")
    if not isinstance(win, dict):
        raise RuntimeError("Steam manifest has no win64 object")
    version = win.get("version")
    if not isinstance(version, str) or not version.isdigit():
        raise RuntimeError("Steam manifest has no numeric win64 version")

    packages: list[tuple[str, str, str, int]] = []
    for logical_name, value in win.items():
        if not isinstance(value, dict):
            continue
        filename = value.get("file")
        sha2 = value.get("sha2")
        size = value.get("size")
        if not isinstance(filename, str) or not isinstance(sha2, str):
            continue
        if not re.fullmatch(r"[0-9a-fA-F]{64}", sha2):
            raise RuntimeError(f"{logical_name}: invalid sha2")
        try:
            expected_size = int(size) if isinstance(size, str) else 0
        except ValueError:
            expected_size = 0
        packages.append((logical_name, filename, sha2.lower(), expected_size))

    if not packages:
        raise RuntimeError("Steam manifest selected zero Win64 packages")
    if not any(name == "steam_win64" for name, *_ in packages):
        raise RuntimeError("Steam manifest did not select the steam_win64 bootstrap package")
    if not any(name == "bins_cef_win64" for name, *_ in packages):
        raise RuntimeError("Steam manifest did not select Win64 CEF")
    return version, packages


def ensure_package(cache: pathlib.Path, filename: str, expected_sha: str, expected_size: int) -> pathlib.Path:
    cache.mkdir(parents=True, exist_ok=True)
    path = cache / filename

    if path.is_file():
        if (not expected_size or path.stat().st_size == expected_size) and sha256_file(path) == expected_sha:
            print(f"STEAMIOS_STEAM_PACKAGE_CACHE_HIT file={filename}")
            return path
        path.unlink()

    errors: list[str] = []
    for base in PACKAGE_BASES:
        url = base + filename
        try:
            data = download(url)
            got = sha256_bytes(data)
            if got != expected_sha:
                raise RuntimeError(f"sha256 {got} != {expected_sha}")
            if expected_size and len(data) != expected_size:
                raise RuntimeError(f"size {len(data)} != {expected_size}")
            tmp = path.with_suffix(path.suffix + ".tmp")
            tmp.write_bytes(data)
            tmp.replace(path)
            print(f"STEAMIOS_STEAM_PACKAGE_FETCHED file={filename} bytes={len(data)}")
            return path
        except Exception as exc:
            errors.append(f"{url}: {exc}")
    raise RuntimeError("all Valve package hosts failed:\n  " + "\n  ".join(errors))


def safe_extract_zip(zip_path: pathlib.Path, dest: pathlib.Path) -> int:
    count = 0
    root = dest.resolve()
    with zipfile.ZipFile(zip_path) as zf:
        for info in zf.infolist():
            name = info.filename.replace("\\", "/")
            if not name or name.endswith("/"):
                (dest / name).mkdir(parents=True, exist_ok=True)
                continue
            target = (dest / name).resolve()
            try:
                target.relative_to(root)
            except ValueError:
                raise RuntimeError(f"unsafe path in {zip_path.name}: {name}")
            target.parent.mkdir(parents=True, exist_ok=True)
            with zf.open(info) as src, target.open("wb") as dst:
                shutil.copyfileobj(src, dst, length=1024 * 1024)
            count += 1
    return count


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cache-dir", required=True, type=pathlib.Path)
    ap.add_argument("--output-dir", required=True, type=pathlib.Path)
    ap.add_argument("--manifest", type=pathlib.Path)
    args = ap.parse_args()

    manifest = get_manifest(args.manifest)
    manifest_sha = sha256_bytes(manifest)
    parsed = parse_vdf(manifest)
    version, packages = select_packages(parsed)

    package_cache = args.cache_dir / "packages"
    assembly = args.cache_dir / "assembled" / manifest_sha / "Steam"
    marker = assembly / ".steamios-bundled-client"

    if not (marker.is_file() and (assembly / "steam.exe").is_file()):
        shutil.rmtree(assembly, ignore_errors=True)
        assembly.mkdir(parents=True, exist_ok=True)
        files = 0
        compressed = 0
        for logical_name, filename, expected_sha, expected_size in packages:
            package = ensure_package(package_cache, filename, expected_sha, expected_size)
            compressed += package.stat().st_size
            try:
                files += safe_extract_zip(package, assembly)
            except zipfile.BadZipFile as exc:
                raise RuntimeError(f"{logical_name}: invalid zip {filename}: {exc}") from exc

        package_dir = assembly / "package"
        package_dir.mkdir(parents=True, exist_ok=True)
        (package_dir / "steam_client_win64").write_bytes(manifest)
        marker.write_text(json.dumps({
            "source": MANIFEST_URL,
            "version": version,
            "manifest_sha256": manifest_sha,
            "packages": len(packages),
            "compressed_package_bytes": compressed,
            "extracted_files": files,
        }, sort_keys=True) + "\n")

    steam_exe = assembly / "steam.exe"
    steamclient = assembly / "steamclient64.dll"
    webhelpers = list(assembly.rglob("steamwebhelper.exe"))
    if not steam_exe.is_file():
        raise RuntimeError("assembled Steam client has no steam.exe")
    if not steamclient.is_file():
        raise RuntimeError("assembled Steam client has no steamclient64.dll")
    if not webhelpers:
        raise RuntimeError("assembled Steam client has no steamwebhelper.exe")

    shutil.rmtree(args.output_dir, ignore_errors=True)
    shutil.copytree(assembly, args.output_dir, symlinks=False)

    total = sum(p.stat().st_size for p in args.output_dir.rglob("*") if p.is_file())
    print(
        "STEAMIOS_FULL_STEAM_CLIENT_OK "
        f"version={version} manifest_sha256={manifest_sha} "
        f"packages={len(packages)} bytes={total} webhelpers={len(webhelpers)}"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise
