#!/bin/bash
set -euo pipefail

R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$R/app/Madeira/x86_64-vcruntime"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

VERSION="14.51.36231.0"
URL="https://download.visualstudio.microsoft.com/download/pr/c1bd4f2c-3672-468e-8480-7ed419dbb641/90E48ADE404E4576D023ABFA374F323555F233982A8805EA9AC63DCA9491A16B/VC_redist.x64.exe"
SHA256="90E48ADE404E4576D023ABFA374F323555F233982A8805EA9AC63DCA9491A16B"
EXE="$TMP/VC_redist.x64.exe"
TREE="$TMP/tree"

command -v curl >/dev/null
command -v 7zz >/dev/null || {
  echo "error: 7zz is required (macOS: brew install sevenzip)" >&2
  exit 1
}

echo "Fetching Microsoft Visual C++ Redistributable x64 $VERSION..."
curl -fL --retry 3 --retry-delay 2 "$URL" -o "$EXE"
actual="$(shasum -a 256 "$EXE" | awk '{print toupper($1)}')"
if [ "$actual" != "$SHA256" ]; then
  echo "error: VC_redist.x64.exe SHA-256 mismatch" >&2
  echo "expected=$SHA256" >&2
  echo "actual=$actual" >&2
  exit 1
fi
echo "VCRUNTIME_INSTALLER_PIN_OK version=$VERSION sha256=$SHA256"

mkdir -p "$TREE/exe"
7zz x -y -tPE "$EXE" "-o$TREE/exe" >/dev/null

# 7-Zip exposes Burn's embedded cabinets as PE resources. Newer installers do
# not consistently preserve a .cab suffix there, so extract every resource
# beneath a CABINET directory regardless of its filename.
cab_resource_count=0
resource_index=0
while IFS= read -r -d '' a; do
  resource_index=$((resource_index + 1))
  dest="$TREE/pe-resource-$resource_index"
  mkdir -p "$dest"
  if 7zz x -y "$a" "-o$dest" >/dev/null 2>&1; then
    cab_resource_count=$((cab_resource_count + 1))
  else
    rmdir "$dest" 2>/dev/null || true
  fi
done < <(find "$TREE/exe/.rsrc" -type f -print0 2>/dev/null || true)
echo "VCRUNTIME_ARCHIVE_RESOURCES extracted=$cab_resource_count scanned=$resource_index"
if [ "$cab_resource_count" -eq 0 ]; then
  echo "=== VC_redist 7-Zip listing (diagnostic) ===" >&2
  7zz l "$EXE" 2>&1 | sed -n '1,260p' >&2 || true
  echo "=== first extracted files ===" >&2
  find "$TREE/exe" -type f -print | sed -n '1,260p' >&2 || true
fi

# Current Microsoft Burn packages expose one or more CAB/MSI payloads. Extract
# every archive recursively into separate directories, then select only
# unmodified AMD64 PE DLLs by exact basename. Wrong-arch ARM64 payloads in the
# x64 redistributable are deliberately ignored.
round=0
while [ "$round" -lt 3 ]; do
  round=$((round + 1))
  found=0
  while IFS= read -r -d '' a; do
    marker="$a.madeira-extracted"
    [ -e "$marker" ] && continue
    found=1
    touch "$marker"
    dest="$TREE/nested-$round-$(printf '%s' "$a" | shasum | cut -c1-16)"
    mkdir -p "$dest"
    7zz x -y "$a" "-o$dest" >/dev/null 2>&1 || true
  done < <(find "$TREE" -type f \( -iname '*.cab' -o -iname '*.msi' \) -print0)
  [ "$found" -eq 0 ] && break
done

rm -rf "$OUT"
mkdir -p "$OUT"

python3 - "$TREE" "$OUT" <<'PY'
from __future__ import annotations
import hashlib, pathlib, shutil, struct, sys

tree = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
wanted = [
    "concrt140.dll",
    "msvcp140.dll",
    "msvcp140_1.dll",
    "msvcp140_2.dll",
    "msvcp140_atomic_wait.dll",
    "msvcp140_codecvt_ids.dll",
    "vcamp140.dll",
    "vccorlib140.dll",
    "vcomp140.dll",
    "vcruntime140.dll",
    "vcruntime140_1.dll",
    "vcruntime140_threads.dll",
]

def pe_info(path: pathlib.Path):
    try:
        d = path.read_bytes()
        if len(d) < 0x100 or d[:2] != b"MZ":
            return None
        pe = struct.unpack_from("<I", d, 0x3C)[0]
        if pe + 24 + 120 > len(d) or d[pe:pe+4] != b"PE\0\0":
            return None
        machine = struct.unpack_from("<H", d, pe + 4)[0]
        opt_magic = struct.unpack_from("<H", d, pe + 24)[0]
        if opt_magic != 0x20B:
            return None
        # IMAGE_DIRECTORY_ENTRY_SECURITY is data-directory entry 4.
        dd = pe + 24 + 112
        cert_off, cert_size = struct.unpack_from("<II", d, dd + 4 * 8)
        signed = bool(cert_size and cert_off and cert_off + cert_size <= len(d))
        return machine, signed, d
    except (OSError, struct.error):
        return None

for name in wanted:
    matches = []
    for p in tree.rglob("*"):
        if not p.is_file() or p.name.lower() != name.lower():
            continue
        info = pe_info(p)
        if not info:
            continue
        machine, signed, data = info
        if machine != 0x8664:
            continue
        if not signed:
            raise SystemExit(f"{p}: AMD64 candidate has no intact Authenticode certificate table")
        matches.append((p, hashlib.sha256(data).hexdigest(), data))

    if not matches:
        raise SystemExit(f"missing required AMD64 runtime DLL: {name}")

    hashes = {h for _, h, _ in matches}
    if len(hashes) != 1:
        detail = "\n".join(f"  {p}: {h}" for p, h, _ in matches)
        raise SystemExit(f"ambiguous differing AMD64 candidates for {name}:\n{detail}")

    src, digest, data = matches[0]
    dst = out / name
    shutil.copyfile(src, dst)
    if hashlib.sha256(dst.read_bytes()).hexdigest() != digest:
        raise SystemExit(f"copy verification failed: {name}")
    print(f"VCRUNTIME_DLL_OK {name} sha256={digest}")

extra = sorted(p.name for p in out.glob("*.dll") if p.name.lower() not in {n.lower() for n in wanted})
if extra:
    raise SystemExit("unexpected runtime DLLs staged: " + ", ".join(extra))
if len(list(out.glob("*.dll"))) != len(wanted):
    raise SystemExit("staged DLL count mismatch")
PY

echo "VCRUNTIME_X64_READY version=$VERSION dir=$OUT"
