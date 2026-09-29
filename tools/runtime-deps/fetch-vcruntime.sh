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

mkdir -p "$TREE/containers" "$TREE/extracted"

# WiX Burn is a PE followed by cabinet streams. Carve every valid CAB by its
# MSCF header instead of relying on an archive tool to expose the attached
# container.
python3 - "$EXE" "$TREE/containers" <<'PY'
from __future__ import annotations
import pathlib, struct, sys

src = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
blob = src.read_bytes()
magic = b"MSCF\0\0\0\0"
offset = 0
count = 0

while True:
    offset = blob.find(magic, offset)
    if offset < 0:
        break
    if offset + 36 <= len(blob):
        size = struct.unpack_from("<I", blob, offset + 8)[0]
        if 36 <= size <= len(blob) - offset:
            path = out / f"container-{count:02d}-{offset:08x}.cab"
            path.write_bytes(blob[offset:offset + size])
            print(f"VCRUNTIME_CAB_CARVED index={count} offset={offset} size={size}")
            count += 1
    offset += 8

if count < 2:
    raise SystemExit(f"expected at least two Burn cabinets, found {count}")
print(f"VCRUNTIME_CAB_CARVE_OK count={count}")
PY

# Extract each carved Burn cabinet and recursively unpack nested CAB and MSI
# payloads. Keep archive paths in their original extracted directories: MSI
# packages reference sibling cab1.cab files by relative path.
python3 - "$TREE/containers" "$TREE/extracted" "$(command -v 7zz)" <<'PY'
from __future__ import annotations
import hashlib, pathlib, subprocess, sys

containers = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
seven = sys.argv[3]

CAB_MAGIC = b"MSCF"
CFB_MAGIC = bytes.fromhex("d0cf11e0a1b11ae1")  # MSI/OLE compound file

queue: list[pathlib.Path] = sorted(containers.glob("*.cab"))
seen: set[str] = set()
index = 0
discovered = {"cab": 0, "msi": 0}

def kind(path: pathlib.Path) -> str | None:
    try:
        head = path.read_bytes()[:8]
    except OSError:
        return None
    if head[:4] == CAB_MAGIC:
        return "cab"
    if head == CFB_MAGIC:
        return "msi"
    return None

while index < len(queue):
    if len(queue) > 128:
        raise SystemExit("unexpected VC runtime archive nesting (>128)")
    archive = queue[index]
    data = archive.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if digest in seen:
        index += 1
        continue
    seen.add(digest)

    archive_kind = kind(archive) or "archive"
    dest = root / f"{index:03d}-{archive_kind}"
    dest.mkdir(parents=True, exist_ok=True)

    result = subprocess.run(
        [seven, "x", "-y", str(archive), f"-o{dest}"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode:
        raise SystemExit(
            f"7-Zip failed extracting {archive_kind} {archive}:\n{result.stderr[-4000:]}"
        )

    for p in sorted(dest.rglob("*")):
        if not p.is_file():
            continue
        k = kind(p)
        if k is None:
            continue
        queue.append(p)  # preserve directory so MSI can resolve sibling CABs
        discovered[k] += 1
    index += 1

print(
    "VCRUNTIME_ARCHIVE_EXTRACT_OK "
    f"unique={len(seen)} queued={len(queue)} "
    f"nested_cab={discovered['cab']} nested_msi={discovered['msi']}"
)
PY

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

def normalized_payload_name(filename: str) -> str | None:
    lower = filename.lower()
    # WiX Burn v14 payload members are commonly:
    #   concrt140.dll_amd64
    #   vcomp140.dll_system_amd64
    # Keep only AMD64 payloads and strip install-directory markers.
    if lower.endswith("_amd64"):
        lower = lower[:-6]
        for marker in ("_system", "_app"):
            if lower.endswith(marker):
                lower = lower[:-len(marker)]
        return lower
    if lower.startswith("f_central_") and lower.endswith("_x64"):
        core = lower[len("f_central_"):-len("_x64")]
        return core if core.endswith(".dll") else core + ".dll"
    if lower.endswith(".dll"):
        return lower
    return None

for name in wanted:
    matches = []
    for p in tree.rglob("*"):
        if not p.is_file() or normalized_payload_name(p.name) != name.lower():
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
