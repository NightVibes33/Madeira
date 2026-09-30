#!/bin/bash
# Rebuild every clean-generated native input required by SteamIOS.app, then
# perform an unsigned Debug iPhoneOS link and package a structurally valid IPA.
set -euo pipefail

R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DERIVED="${STEAMOS_DERIVED_DATA:-$R/build/steamos-ios-derived}"
ARTIFACTS="${STEAMOS_ARTIFACTS:-$R/artifacts}"
APP="$DERIVED/Build/Products/Debug-iphoneos/SteamIOS.app"
IPA="$ARTIFACTS/SteamIOS.ipa"

cd "$R"

echo "=== SteamIOS clean app build ==="
python3 tools/verify-madeira-pins.py

for tool in cmake ninja meson python3 xcodebuild; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "error: required clean-build host tool missing: $tool" >&2
    exit 1
  }
done
echo "CLEAN_APP_HOST_TOOLS_OK"

if [[ "${STEAMOS_SKIP_NATIVE_REBUILD:-0}" != "1" ]]; then
# Clean-generated dependency sources.
git submodule update --init --recursive --depth 1 FEX
git submodule update --init --depth 1 wine
git submodule update --init --depth 1 research/dxmt
git -C research/dxmt submodule update --init --recursive --depth 1 include/native/directx

bash tools/bootstrap/fetch-llvm-mingw.sh
bash tools/runtime-deps/fetch-freetype.sh
bash tools/runtime-deps/fetch-llvm-project.sh
bash tools/runtime-deps/fetch-vcruntime.sh

# Native libraries linked directly by the iOS app.
bash build/gnutls-ios/build.sh
bash build/freetype-ios/build.sh

export PATH="$R/toolchains/llvm-mingw-20260922-ucrt-macos-universal/bin:/opt/homebrew/opt/bison/bin:$PATH"

# FEX's configure-time Python probes import packaging.version and fall back to
# pkg_resources. Hosted macOS Python images intentionally do not guarantee
# either module. Use an isolated venv so clean builds are reproducible and do
# not depend on runner-global Python packages.
PY_VENV="$R/build/steamos-python"
rm -rf "$PY_VENV"
python3 -m venv "$PY_VENV"
"$PY_VENV/bin/python" -m pip install --disable-pip-version-check --quiet 'packaging==24.2'
export PATH="$PY_VENV/bin:$PATH"
python3 -c 'from packaging.version import Version; assert Version("24.2") == Version("24.2"); print("STEAMOS_IOS_FEX_PYTHON_DEPS_OK packaging=24.2")'

# Rebuild the Windows-side FEX translators from the exact pinned FEX source.
# xtajit64.dll serves x86-64/ARM64EC; xtajit.dll is the WoW64 backend used by
# 32-bit SteamSetup.exe and any 32-bit Steam/game children.
bash build/fex-arm64ec/build.sh
bash build/fex-wow64/build.sh

# Wine host headers are consumed by the unix-side archive build.
mkdir -p wine/build-macos
if [ ! -f wine/build-macos/config.status ]; then
  (
    cd wine/build-macos
    ../configure --without-x --disable-tests
  )
fi

# SteamSetup.exe is PE32. Build the complete 32-bit Wine farm plus DXMT i386
# frontends before packaging; app/Madeira/i386-windows is intentionally
# tracked empty and must never remain empty in a bootable Windows-Steam IPA.
bash build/wine-i386/build.sh

bash build/wineserver/bootstrap-base.sh
bash build/wineserver/build.sh all
bash build/wine-pe/build-ntdll.sh
bash build/ntdll-unix/build.sh
bash build/win32u-unix/build.sh

bash build/llvm-ios/build.sh

# Xcode 27 ships the Metal compiler as an optional component on hosted runners.
# DXMT's embedded AIR shader headers require it even though final presentation
# targets iPhoneOS.
if ! xcrun --sdk macosx --find metal >/dev/null 2>&1; then
  xcodebuild -downloadComponent MetalToolchain
fi
xcrun --sdk macosx --find metal >/dev/null
xcrun --sdk macosx --find metallib >/dev/null
bash build/dxmt-ios/build.sh
bash build/stage-licenses.sh

else
  echo "STEAMOS_IOS_NATIVE_REBUILD_SKIPPED"
fi

# Fail before Xcode if any clean-generated link/resource input is absent.
for f in app/Madeira/libwineserver.a app/Madeira/libntdll_unix.a app/Madeira/libwin32u_unix.a app/Madeira/libdxmt_combined.a; do
  test -s "$f" || { echo "error: missing clean app input: $f" >&2; exit 1; }
done

test "$(find app/Madeira/x86_64-vcruntime -maxdepth 1 -type f -name '*.dll' | wc -l | tr -d ' ')" = "12"

# Windows Steam bootstrap cannot run without a real PE32 farm and both FEX
# translator DLLs. Key files catch partial builds; the count catches an
# accidentally tiny hand-picked farm that would fail as soon as Steam loads
# another system DLL.
for f in \
  app/Madeira/arm64ec-windows/xtajit64.dll \
  app/Madeira/aarch64-windows/xtajit.dll \
  app/Madeira/aarch64-windows/wow64.dll \
  app/Madeira/aarch64-windows/wow64win.dll \
  app/Madeira/i386-windows/ntdll.dll \
  app/Madeira/i386-windows/kernel32.dll \
  app/Madeira/i386-windows/kernelbase.dll \
  app/Madeira/i386-windows/user32.dll \
  app/Madeira/i386-windows/advapi32.dll \
  app/Madeira/i386-windows/shell32.dll \
  app/Madeira/i386-windows/winhttp.dll \
  app/Madeira/i386-windows/d3d11.dll \
  app/Madeira/i386-windows/dxgi.dll \
  app/Madeira/i386-windows/winemetal.dll; do
  test -s "$f" || { echo "error: missing WoW64/Steam payload: $f" >&2; exit 1; }
done
i386_count="$(find app/Madeira/i386-windows -maxdepth 1 -type f ! -name '.gitkeep' | wc -l | tr -d ' ')"
[ "$i386_count" -ge 500 ] || {
  echo "error: i386 Wine farm is incomplete ($i386_count files; expected >=500)" >&2
  exit 1
}
echo "STEAMOS_IOS_WOW64_PAYLOAD_OK files=$i386_count"

# A complete, already-updated Windows Steam client is assembled by the
# workflow's Windows job. Merge that finished client directly into the bundled
# Wine prefix. The iPhone never runs SteamSetup.exe.
STEAM_PAYLOAD_DIR="$R/build/steamos-steam-payload"
STEAM_PAYLOAD="$STEAM_PAYLOAD_DIR/SteamPayload.tar.gz"
STEAM_PAYLOAD_META="$STEAM_PAYLOAD_DIR/SteamPayload.json"

test -s "$STEAM_PAYLOAD" || {
  echo "error: preinstalled SteamPayload.tar.gz was not downloaded from the Windows staging job" >&2
  exit 1
}
test -s "$STEAM_PAYLOAD_META" || {
  echo "error: SteamPayload.json metadata missing" >&2
  exit 1
}

python3 - "$STEAM_PAYLOAD" "$STEAM_PAYLOAD_META" <<'PY'
import json, pathlib, sys, tarfile
payload = pathlib.Path(sys.argv[1])
meta = pathlib.Path(sys.argv[2])
required = {
    "Steam/steam.exe",
    "Steam/steamclient.dll",
    "Steam/steamclient64.dll",
    "Steam/steamui.dll",
    "Steam/bin/cef/cef.win7x64/steamwebhelper.exe",
}
with tarfile.open(payload, "r:gz") as tf:
    names = {n.replace("\\", "/").lstrip("./") for n in tf.getnames()}
missing = sorted(required - names)
if missing:
    raise SystemExit("error: preinstalled Steam payload incomplete: " + ", ".join(missing))
if not ({"Steam/package/steam_client_win64.installed", "Steam/package/steam_client_win32.installed"} & names):
    raise SystemExit("error: preinstalled Steam payload has no installed client manifest")
j = json.loads(meta.read_text(encoding="utf-8-sig"))
if not j.get("payload_sha256") or not j.get("source_manifest_sha256"):
    raise SystemExit("error: Steam payload metadata is incomplete")
print(f"STEAMIOS_FULL_STEAM_STAGE_OK archive_bytes={payload.stat().st_size} files={j.get('expanded_files')}")
PY

# Expand the base Wine prefix and the fully-updated Steam archive, replace only
# the Steam subtree, then rebuild one self-contained prefix archive.
PREFIX_TEMPLATE="$R/app/Madeira/prefix-template.tar.gz"
PREFIX_WORK="$(mktemp -d)"
STEAM_WORK="$(mktemp -d)"
PREFIX_NEW="$R/app/Madeira/prefix-template.tar.gz.full-steam"
trap 'rm -rf "$PREFIX_WORK" "$STEAM_WORK" "$PREFIX_NEW"' EXIT

tar -xzf "$PREFIX_TEMPLATE" -C "$PREFIX_WORK"
tar -xzf "$STEAM_PAYLOAD" -C "$STEAM_WORK"

DRIVE_C="$(find "$PREFIX_WORK" -type d -name drive_c -print -quit)"
STEAM_SOURCE="$STEAM_WORK/Steam"
if [ -z "$DRIVE_C" ] || [ ! -d "$DRIVE_C" ]; then
  echo "error: prefix-template.tar.gz has no drive_c" >&2
  exit 1
fi
test -d "$STEAM_SOURCE" || {
  echo "error: SteamPayload.tar.gz has no Steam root" >&2
  exit 1
}

STEAM_DEST="$DRIVE_C/Program Files (x86)/Steam"
rm -rf "$STEAM_DEST"
mkdir -p "$(dirname "$STEAM_DEST")"
/usr/bin/ditto "$STEAM_SOURCE" "$STEAM_DEST"
cp "$STEAM_PAYLOAD_META" "$STEAM_DEST/.steamios-bundled-client"

test -s "$STEAM_DEST/steam.exe"
test -s "$STEAM_DEST/steamclient64.dll"
test -s "$STEAM_DEST/.steamios-bundled-client"
find "$STEAM_DEST" -type f -iname 'steamwebhelper.exe' -print -quit | grep -q . || {
  echo "error: merged Steam tree has no steamwebhelper.exe" >&2
  exit 1
}

# The in-app extractor understands ustar prefix fields; avoid pax metadata so
# migration of the Steam subtree into an older prefix is deterministic.
if [ -d "$PREFIX_WORK/prefix" ]; then
  tar --format=ustar -czf "$PREFIX_NEW" -C "$PREFIX_WORK" prefix
else
  tar --format=ustar -czf "$PREFIX_NEW" -C "$PREFIX_WORK" .
fi
mv "$PREFIX_NEW" "$PREFIX_TEMPLATE"

PREFIX_LIST="$PREFIX_WORK/prefix-template.list"
tar -tzf "$PREFIX_TEMPLATE" > "$PREFIX_LIST"
for required in   'drive_c/Program Files (x86)/Steam/steam.exe'   'drive_c/Program Files (x86)/Steam/steamclient64.dll'   'drive_c/Program Files (x86)/Steam/.steamios-bundled-client'; do
  grep -Fq "$required" "$PREFIX_LIST" || {
    echo "error: rebuilt prefix missing $required" >&2
    exit 1
  }
done
grep -Eiq 'drive_c/Program Files \(x86\)/Steam/.*/steamwebhelper\.exe$' "$PREFIX_LIST" || {
  echo "error: rebuilt prefix missing steamwebhelper.exe" >&2
  exit 1
}
steam_tree_bytes="$(du -sk "$STEAM_DEST" | awk '{print $1 * 1024}')"
echo "STEAMIOS_PREFIX_FULL_STEAM_OK bytes=$steam_tree_bytes archive=$(stat -f%z "$PREFIX_TEMPLATE")"

# Materialize the SteamIOS app icon from the exact user-supplied JPEG source.
# Keep the source bytes in git and let macOS/Xcode produce the required 1024 PNG.
ICON_SOURCE="$R/build/steamos-ios/assets/SteamIOS-AppIcon-source.jpeg"
ICON_DEST="$R/app/Madeira/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
ICON_SHA256="ccbbe73a8f06d5b5cd605adf313d8cafa7de7b544eed7f3ca1fd4334953dcea4"
test -s "$ICON_SOURCE" || { echo "error: missing SteamIOS app icon source" >&2; exit 1; }
actual_icon_sha="$(shasum -a 256 "$ICON_SOURCE" | awk '{print $1}')"
[ "$actual_icon_sha" = "$ICON_SHA256" ] || {
  echo "error: SteamIOS app icon source checksum mismatch" >&2
  exit 1
}
mkdir -p "$(dirname "$ICON_DEST")"
/usr/bin/sips -s format png -z 1024 1024 "$ICON_SOURCE" --out "$ICON_DEST" >/dev/null
test -s "$ICON_DEST" || { echo "error: failed to materialize AppIcon-1024.png" >&2; exit 1; }
icon_dims="$(/usr/bin/sips -g pixelWidth -g pixelHeight "$ICON_DEST" 2>/dev/null)"
printf '%s\n' "$icon_dims" | grep -q 'pixelWidth: 1024'
printf '%s\n' "$icon_dims" | grep -q 'pixelHeight: 1024'
echo "STEAMIOS_APP_ICON_OK sha256=$actual_icon_sha"

rm -rf "$DERIVED"
mkdir -p "$ARTIFACTS"

xcodebuild   -project app/Madeira.xcodeproj   -scheme Madeira   -configuration Debug   -destination 'generic/platform=iOS'   -derivedDataPath "$DERIVED"   CODE_SIGNING_ALLOWED=NO   CODE_SIGNING_REQUIRED=NO   build

test -d "$APP"
test -s "$APP/Info.plist"
test -s "$APP/SteamIOS"

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
[ "$bundle_id" = "com.nightvibes33.steamios" ] || {
  echo "error: packaged bundle id is '$bundle_id' (expected com.nightvibes33.steamios)" >&2
  exit 1
}
test -s "$APP/prefix-template.tar.gz" || {
  echo "error: packaged prefix template missing" >&2
  exit 1
}
PACKAGED_PREFIX_LIST="$PREFIX_WORK/packaged-prefix-template.list"
tar -tzf "$APP/prefix-template.tar.gz" > "$PACKAGED_PREFIX_LIST"
for required in   'drive_c/Program Files (x86)/Steam/steam.exe'   'drive_c/Program Files (x86)/Steam/steamclient64.dll'   'drive_c/Program Files (x86)/Steam/.steamios-bundled-client'; do
  grep -Fq "$required" "$PACKAGED_PREFIX_LIST" || {
    echo "error: packaged full Steam client missing $required" >&2
    exit 1
  }
done
grep -Eiq 'drive_c/Program Files \(x86\)/Steam/.*/steamwebhelper\.exe$' "$PACKAGED_PREFIX_LIST" || {
  echo "error: packaged full Steam client missing steamwebhelper.exe" >&2
  exit 1
}
echo "STEAMIOS_PACKAGED_FULL_STEAM_OK bytes=$(stat -f%z "$APP/prefix-template.tar.gz")"

test -s "$APP/Assets.car" || {
  echo "error: compiled asset catalog missing; SteamIOS app icon was not packaged" >&2
  exit 1
}
echo "STEAMIOS_PACKAGED_IDENTITY_OK bundle=$bundle_id assets=$(stat -f%z "$APP/Assets.car")"

/usr/bin/codesign --verify --verbose=2 "$APP/d3d12/libmetalirconverter.dylib" >/dev/null 2>&1 || {
  echo "error: bundled Metal Shader Converter dylib is not code-signed" >&2
  exit 1
}

bash tools/packaging/package-ipa.sh "$APP" "$IPA"

python3 - "$R" "$APP" "$IPA" "$ARTIFACTS/build-info.json" <<'PY'
from __future__ import annotations
import hashlib, json, pathlib, plistlib, subprocess, sys

root = pathlib.Path(sys.argv[1])
app = pathlib.Path(sys.argv[2])
ipa = pathlib.Path(sys.argv[3])
out = pathlib.Path(sys.argv[4])

def cmd(*args: str, cwd: pathlib.Path | None = None) -> str:
    return subprocess.check_output(args, cwd=cwd, text=True).strip()

def rev(path: str) -> str | None:
    p = root / path
    if not (p / ".git").exists() and not (root / ".git" / "modules" / path).exists():
        try:
            return cmd("git", "-C", str(p), "rev-parse", "HEAD")
        except Exception:
            return None
    try:
        return cmd("git", "-C", str(p), "rev-parse", "HEAD")
    except Exception:
        return None

def sha256(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

xcode = cmd("xcodebuild", "-version").splitlines()
with (app / "Info.plist").open("rb") as f:
    plist = plistlib.load(f)
executable = plist.get("CFBundleExecutable")
if not executable or not (app / executable).is_file():
    raise SystemExit("built app has no valid CFBundleExecutable")

info = {
    "commit": cmd("git", "rev-parse", "HEAD", cwd=root),
    "fex": rev("FEX"),
    "wine": rev("wine"),
    "dxmt": rev("research/dxmt"),
    "llvm": rev("toolchains/llvm-project"),
    "llvm_mingw": {
        "release": "20260922",
        "archive_sha256": "52e5f5a7b131021d0c39a37a38fa380a1da7885cd04bd61afd0cd4ecfb8bc1f3",
    },
    "vkd3d": None,
    "moltenvk": None,
    "xcode": xcode,
    "sdk": cmd("xcrun", "--sdk", "iphoneos", "--show-sdk-version"),
    "app": {
        "path": str(app),
        "bundle_identifier": plist.get("CFBundleIdentifier"),
        "executable": executable,
        "executable_sha256": sha256(app / executable),
    },
    "ipa": {
        "path": str(ipa),
        "sha256": sha256(ipa),
        "size": ipa.stat().st_size,
    },
}
out.write_text(json.dumps(info, indent=2, sort_keys=True) + "\n")
print(f"BUILD_INFO_OK {out}")
PY

(
  cd "$ARTIFACTS"
  shasum -a 256 SteamIOS.ipa build-info.json > SHA256SUMS
)

echo "STEAMIOS_CLEAN_APP_OK app=$APP ipa=$IPA build_info=$ARTIFACTS/build-info.json"
 "$PREFIX_LIST" || {
  echo "error: rebuilt prefix missing steamwebhelper.exe" >&2
  exit 1
}

steam_tree_bytes="$(du -sk "$STEAM_DEST" | awk '{print $1 * 1024}')"
echo "STEAMIOS_PREFIX_FULL_STEAM_OK bytes=$steam_tree_bytes archive=$(stat -f%z "$PREFIX_TEMPLATE")"

# Materialize the SteamIOS app icon from the exact user-supplied JPEG source.
# Keep the source bytes in git and let macOS/Xcode produce the required 1024 PNG.
ICON_SOURCE="$R/build/steamos-ios/assets/SteamIOS-AppIcon-source.jpeg"
ICON_DEST="$R/app/Madeira/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
ICON_SHA256="ccbbe73a8f06d5b5cd605adf313d8cafa7de7b544eed7f3ca1fd4334953dcea4"
test -s "$ICON_SOURCE" || { echo "error: missing SteamIOS app icon source" >&2; exit 1; }
actual_icon_sha="$(shasum -a 256 "$ICON_SOURCE" | awk '{print $1}')"
[ "$actual_icon_sha" = "$ICON_SHA256" ] || {
  echo "error: SteamIOS app icon source checksum mismatch" >&2
  exit 1
}
mkdir -p "$(dirname "$ICON_DEST")"
/usr/bin/sips -s format png -z 1024 1024 "$ICON_SOURCE" --out "$ICON_DEST" >/dev/null
test -s "$ICON_DEST" || { echo "error: failed to materialize AppIcon-1024.png" >&2; exit 1; }
icon_dims="$(/usr/bin/sips -g pixelWidth -g pixelHeight "$ICON_DEST" 2>/dev/null)"
printf '%s\n' "$icon_dims" | grep -q 'pixelWidth: 1024'
printf '%s\n' "$icon_dims" | grep -q 'pixelHeight: 1024'
echo "STEAMIOS_APP_ICON_OK sha256=$actual_icon_sha"

rm -rf "$DERIVED"
mkdir -p "$ARTIFACTS"

xcodebuild   -project app/Madeira.xcodeproj   -scheme Madeira   -configuration Debug   -destination 'generic/platform=iOS'   -derivedDataPath "$DERIVED"   CODE_SIGNING_ALLOWED=NO   CODE_SIGNING_REQUIRED=NO   build

test -d "$APP"
test -s "$APP/Info.plist"
test -s "$APP/SteamIOS"

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
[ "$bundle_id" = "com.nightvibes33.steamios" ] || {
  echo "error: packaged bundle id is '$bundle_id' (expected com.nightvibes33.steamios)" >&2
  exit 1
}
test -s "$APP/prefix-template.tar.gz" || {
  echo "error: packaged prefix template missing" >&2
  exit 1
}
for required in   'drive_c/Program Files (x86)/Steam/steam.exe'   'drive_c/Program Files (x86)/Steam/steamclient64.dll'   'drive_c/Program Files (x86)/Steam/.steamios-bundled-client'; do
  tar -tzf "$APP/prefix-template.tar.gz" | grep -Fq "$required" || {
    echo "error: packaged full Steam client missing $required" >&2
    exit 1
  }
done
tar -tzf "$APP/prefix-template.tar.gz" | grep -Eiq 'drive_c/Program Files \(x86\)/Steam/.*/steamwebhelper\.exe$' || {
  echo "error: packaged full Steam client missing steamwebhelper.exe" >&2
  exit 1
}
echo "STEAMIOS_PACKAGED_FULL_STEAM_OK bytes=$(stat -f%z "$APP/prefix-template.tar.gz")"

test -s "$APP/Assets.car" || {
  echo "error: compiled asset catalog missing; SteamIOS app icon was not packaged" >&2
  exit 1
}
echo "STEAMIOS_PACKAGED_IDENTITY_OK bundle=$bundle_id assets=$(stat -f%z "$APP/Assets.car")"

/usr/bin/codesign --verify --verbose=2 "$APP/d3d12/libmetalirconverter.dylib" >/dev/null 2>&1 || {
  echo "error: bundled Metal Shader Converter dylib is not code-signed" >&2
  exit 1
}

bash tools/packaging/package-ipa.sh "$APP" "$IPA"

python3 - "$R" "$APP" "$IPA" "$ARTIFACTS/build-info.json" <<'PY'
from __future__ import annotations
import hashlib, json, pathlib, plistlib, subprocess, sys

root = pathlib.Path(sys.argv[1])
app = pathlib.Path(sys.argv[2])
ipa = pathlib.Path(sys.argv[3])
out = pathlib.Path(sys.argv[4])

def cmd(*args: str, cwd: pathlib.Path | None = None) -> str:
    return subprocess.check_output(args, cwd=cwd, text=True).strip()

def rev(path: str) -> str | None:
    p = root / path
    if not (p / ".git").exists() and not (root / ".git" / "modules" / path).exists():
        try:
            return cmd("git", "-C", str(p), "rev-parse", "HEAD")
        except Exception:
            return None
    try:
        return cmd("git", "-C", str(p), "rev-parse", "HEAD")
    except Exception:
        return None

def sha256(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

xcode = cmd("xcodebuild", "-version").splitlines()
with (app / "Info.plist").open("rb") as f:
    plist = plistlib.load(f)
executable = plist.get("CFBundleExecutable")
if not executable or not (app / executable).is_file():
    raise SystemExit("built app has no valid CFBundleExecutable")

info = {
    "commit": cmd("git", "rev-parse", "HEAD", cwd=root),
    "fex": rev("FEX"),
    "wine": rev("wine"),
    "dxmt": rev("research/dxmt"),
    "llvm": rev("toolchains/llvm-project"),
    "llvm_mingw": {
        "release": "20260922",
        "archive_sha256": "52e5f5a7b131021d0c39a37a38fa380a1da7885cd04bd61afd0cd4ecfb8bc1f3",
    },
    "vkd3d": None,
    "moltenvk": None,
    "xcode": xcode,
    "sdk": cmd("xcrun", "--sdk", "iphoneos", "--show-sdk-version"),
    "app": {
        "path": str(app),
        "bundle_identifier": plist.get("CFBundleIdentifier"),
        "executable": executable,
        "executable_sha256": sha256(app / executable),
    },
    "ipa": {
        "path": str(ipa),
        "sha256": sha256(ipa),
        "size": ipa.stat().st_size,
    },
}
out.write_text(json.dumps(info, indent=2, sort_keys=True) + "\n")
print(f"BUILD_INFO_OK {out}")
PY

(
  cd "$ARTIFACTS"
  shasum -a 256 SteamIOS.ipa build-info.json > SHA256SUMS
)

echo "STEAMIOS_CLEAN_APP_OK app=$APP ipa=$IPA build_info=$ARTIFACTS/build-info.json"
 "$PACKAGED_PREFIX_LIST" || {
  echo "error: packaged full Steam client missing steamwebhelper.exe" >&2
  exit 1
}
echo "STEAMIOS_PACKAGED_FULL_STEAM_OK bytes=$(stat -f%z "$APP/prefix-template.tar.gz")"

test -s "$APP/Assets.car" || {
  echo "error: compiled asset catalog missing; SteamIOS app icon was not packaged" >&2
  exit 1
}
echo "STEAMIOS_PACKAGED_IDENTITY_OK bundle=$bundle_id assets=$(stat -f%z "$APP/Assets.car")"

/usr/bin/codesign --verify --verbose=2 "$APP/d3d12/libmetalirconverter.dylib" >/dev/null 2>&1 || {
  echo "error: bundled Metal Shader Converter dylib is not code-signed" >&2
  exit 1
}

bash tools/packaging/package-ipa.sh "$APP" "$IPA"

python3 - "$R" "$APP" "$IPA" "$ARTIFACTS/build-info.json" <<'PY'
from __future__ import annotations
import hashlib, json, pathlib, plistlib, subprocess, sys

root = pathlib.Path(sys.argv[1])
app = pathlib.Path(sys.argv[2])
ipa = pathlib.Path(sys.argv[3])
out = pathlib.Path(sys.argv[4])

def cmd(*args: str, cwd: pathlib.Path | None = None) -> str:
    return subprocess.check_output(args, cwd=cwd, text=True).strip()

def rev(path: str) -> str | None:
    p = root / path
    if not (p / ".git").exists() and not (root / ".git" / "modules" / path).exists():
        try:
            return cmd("git", "-C", str(p), "rev-parse", "HEAD")
        except Exception:
            return None
    try:
        return cmd("git", "-C", str(p), "rev-parse", "HEAD")
    except Exception:
        return None

def sha256(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

xcode = cmd("xcodebuild", "-version").splitlines()
with (app / "Info.plist").open("rb") as f:
    plist = plistlib.load(f)
executable = plist.get("CFBundleExecutable")
if not executable or not (app / executable).is_file():
    raise SystemExit("built app has no valid CFBundleExecutable")

info = {
    "commit": cmd("git", "rev-parse", "HEAD", cwd=root),
    "fex": rev("FEX"),
    "wine": rev("wine"),
    "dxmt": rev("research/dxmt"),
    "llvm": rev("toolchains/llvm-project"),
    "llvm_mingw": {
        "release": "20260922",
        "archive_sha256": "52e5f5a7b131021d0c39a37a38fa380a1da7885cd04bd61afd0cd4ecfb8bc1f3",
    },
    "vkd3d": None,
    "moltenvk": None,
    "xcode": xcode,
    "sdk": cmd("xcrun", "--sdk", "iphoneos", "--show-sdk-version"),
    "app": {
        "path": str(app),
        "bundle_identifier": plist.get("CFBundleIdentifier"),
        "executable": executable,
        "executable_sha256": sha256(app / executable),
    },
    "ipa": {
        "path": str(ipa),
        "sha256": sha256(ipa),
        "size": ipa.stat().st_size,
    },
}
out.write_text(json.dumps(info, indent=2, sort_keys=True) + "\n")
print(f"BUILD_INFO_OK {out}")
PY

(
  cd "$ARTIFACTS"
  shasum -a 256 SteamIOS.ipa build-info.json > SHA256SUMS
)

echo "STEAMIOS_CLEAN_APP_OK app=$APP ipa=$IPA build_info=$ARTIFACTS/build-info.json"
 "$PREFIX_LIST" || {
  echo "error: rebuilt prefix missing steamwebhelper.exe" >&2
  exit 1
}

steam_tree_bytes="$(du -sk "$STEAM_DEST" | awk '{print $1 * 1024}')"
echo "STEAMIOS_PREFIX_FULL_STEAM_OK bytes=$steam_tree_bytes archive=$(stat -f%z "$PREFIX_TEMPLATE")"

# Materialize the SteamIOS app icon from the exact user-supplied JPEG source.
# Keep the source bytes in git and let macOS/Xcode produce the required 1024 PNG.
ICON_SOURCE="$R/build/steamos-ios/assets/SteamIOS-AppIcon-source.jpeg"
ICON_DEST="$R/app/Madeira/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
ICON_SHA256="ccbbe73a8f06d5b5cd605adf313d8cafa7de7b544eed7f3ca1fd4334953dcea4"
test -s "$ICON_SOURCE" || { echo "error: missing SteamIOS app icon source" >&2; exit 1; }
actual_icon_sha="$(shasum -a 256 "$ICON_SOURCE" | awk '{print $1}')"
[ "$actual_icon_sha" = "$ICON_SHA256" ] || {
  echo "error: SteamIOS app icon source checksum mismatch" >&2
  exit 1
}
mkdir -p "$(dirname "$ICON_DEST")"
/usr/bin/sips -s format png -z 1024 1024 "$ICON_SOURCE" --out "$ICON_DEST" >/dev/null
test -s "$ICON_DEST" || { echo "error: failed to materialize AppIcon-1024.png" >&2; exit 1; }
icon_dims="$(/usr/bin/sips -g pixelWidth -g pixelHeight "$ICON_DEST" 2>/dev/null)"
printf '%s\n' "$icon_dims" | grep -q 'pixelWidth: 1024'
printf '%s\n' "$icon_dims" | grep -q 'pixelHeight: 1024'
echo "STEAMIOS_APP_ICON_OK sha256=$actual_icon_sha"

rm -rf "$DERIVED"
mkdir -p "$ARTIFACTS"

xcodebuild   -project app/Madeira.xcodeproj   -scheme Madeira   -configuration Debug   -destination 'generic/platform=iOS'   -derivedDataPath "$DERIVED"   CODE_SIGNING_ALLOWED=NO   CODE_SIGNING_REQUIRED=NO   build

test -d "$APP"
test -s "$APP/Info.plist"
test -s "$APP/SteamIOS"

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
[ "$bundle_id" = "com.nightvibes33.steamios" ] || {
  echo "error: packaged bundle id is '$bundle_id' (expected com.nightvibes33.steamios)" >&2
  exit 1
}
test -s "$APP/prefix-template.tar.gz" || {
  echo "error: packaged prefix template missing" >&2
  exit 1
}
for required in   'drive_c/Program Files (x86)/Steam/steam.exe'   'drive_c/Program Files (x86)/Steam/steamclient64.dll'   'drive_c/Program Files (x86)/Steam/.steamios-bundled-client'; do
  tar -tzf "$APP/prefix-template.tar.gz" | grep -Fq "$required" || {
    echo "error: packaged full Steam client missing $required" >&2
    exit 1
  }
done
tar -tzf "$APP/prefix-template.tar.gz" | grep -Eiq 'drive_c/Program Files \(x86\)/Steam/.*/steamwebhelper\.exe$' || {
  echo "error: packaged full Steam client missing steamwebhelper.exe" >&2
  exit 1
}
echo "STEAMIOS_PACKAGED_FULL_STEAM_OK bytes=$(stat -f%z "$APP/prefix-template.tar.gz")"

test -s "$APP/Assets.car" || {
  echo "error: compiled asset catalog missing; SteamIOS app icon was not packaged" >&2
  exit 1
}
echo "STEAMIOS_PACKAGED_IDENTITY_OK bundle=$bundle_id assets=$(stat -f%z "$APP/Assets.car")"

/usr/bin/codesign --verify --verbose=2 "$APP/d3d12/libmetalirconverter.dylib" >/dev/null 2>&1 || {
  echo "error: bundled Metal Shader Converter dylib is not code-signed" >&2
  exit 1
}

bash tools/packaging/package-ipa.sh "$APP" "$IPA"

python3 - "$R" "$APP" "$IPA" "$ARTIFACTS/build-info.json" <<'PY'
from __future__ import annotations
import hashlib, json, pathlib, plistlib, subprocess, sys

root = pathlib.Path(sys.argv[1])
app = pathlib.Path(sys.argv[2])
ipa = pathlib.Path(sys.argv[3])
out = pathlib.Path(sys.argv[4])

def cmd(*args: str, cwd: pathlib.Path | None = None) -> str:
    return subprocess.check_output(args, cwd=cwd, text=True).strip()

def rev(path: str) -> str | None:
    p = root / path
    if not (p / ".git").exists() and not (root / ".git" / "modules" / path).exists():
        try:
            return cmd("git", "-C", str(p), "rev-parse", "HEAD")
        except Exception:
            return None
    try:
        return cmd("git", "-C", str(p), "rev-parse", "HEAD")
    except Exception:
        return None

def sha256(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

xcode = cmd("xcodebuild", "-version").splitlines()
with (app / "Info.plist").open("rb") as f:
    plist = plistlib.load(f)
executable = plist.get("CFBundleExecutable")
if not executable or not (app / executable).is_file():
    raise SystemExit("built app has no valid CFBundleExecutable")

info = {
    "commit": cmd("git", "rev-parse", "HEAD", cwd=root),
    "fex": rev("FEX"),
    "wine": rev("wine"),
    "dxmt": rev("research/dxmt"),
    "llvm": rev("toolchains/llvm-project"),
    "llvm_mingw": {
        "release": "20260922",
        "archive_sha256": "52e5f5a7b131021d0c39a37a38fa380a1da7885cd04bd61afd0cd4ecfb8bc1f3",
    },
    "vkd3d": None,
    "moltenvk": None,
    "xcode": xcode,
    "sdk": cmd("xcrun", "--sdk", "iphoneos", "--show-sdk-version"),
    "app": {
        "path": str(app),
        "bundle_identifier": plist.get("CFBundleIdentifier"),
        "executable": executable,
        "executable_sha256": sha256(app / executable),
    },
    "ipa": {
        "path": str(ipa),
        "sha256": sha256(ipa),
        "size": ipa.stat().st_size,
    },
}
out.write_text(json.dumps(info, indent=2, sort_keys=True) + "\n")
print(f"BUILD_INFO_OK {out}")
PY

(
  cd "$ARTIFACTS"
  shasum -a 256 SteamIOS.ipa build-info.json > SHA256SUMS
)

echo "STEAMIOS_CLEAN_APP_OK app=$APP ipa=$IPA build_info=$ARTIFACTS/build-info.json"
