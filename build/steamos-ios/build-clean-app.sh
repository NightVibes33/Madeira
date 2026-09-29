#!/bin/bash
# Rebuild every clean-generated native input required by Madeira.app, then
# perform an unsigned Debug iPhoneOS link and package a structurally valid IPA.
set -euo pipefail

R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DERIVED="${STEAMOS_DERIVED_DATA:-$R/build/steamos-ios-derived}"
ARTIFACTS="${STEAMOS_ARTIFACTS:-$R/artifacts}"
APP="$DERIVED/Build/Products/Debug-iphoneos/Madeira.app"
IPA="$ARTIFACTS/SteamOS-iOS.ipa"

cd "$R"

echo "=== SteamOS-iOS clean app build ==="
python3 tools/verify-madeira-pins.py

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
bash build/fex-ios/build.sh

export PATH="$R/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin:/opt/homebrew/opt/bison/bin:$PATH"

# Wine host headers are consumed by the unix-side archive build.
mkdir -p wine/build-macos
if [ ! -f wine/build-macos/config.status ]; then
  (
    cd wine/build-macos
    ../configure --without-x --disable-tests
  )
fi

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

# Fail before Xcode if any clean-generated link/resource input is absent.
for f in   FEX/build-ios/FEXCore/Source/libFEXCore.a   FEX/build-ios/FEXCore/Source/libFEXCore_Base.a   FEX/build-ios/FEXCore/Source/libJemallocLibs.a   FEX/build-ios/External/fmt/libfmt.a   FEX/build-ios/External/cephes/libcephes_128bit.a   FEX/build-ios/External/SoftFloat-3e/libsoftfloat_3e.a   FEX/build-ios/External/xxhash/cmake_unofficial/libxxhash.a   app/Madeira/libwineserver.a   app/Madeira/libntdll_unix.a   app/Madeira/libwin32u_unix.a   app/Madeira/libdxmt_combined.a; do
  test -s "$f" || { echo "error: missing clean app input: $f" >&2; exit 1; }
done

test "$(find app/Madeira/x86_64-vcruntime -maxdepth 1 -type f -name '*.dll' | wc -l | tr -d ' ')" = "12"

rm -rf "$DERIVED"
mkdir -p "$ARTIFACTS"

xcodebuild   -project app/Madeira.xcodeproj   -scheme Madeira   -configuration Debug   -destination 'generic/platform=iOS'   -derivedDataPath "$DERIVED"   CODE_SIGNING_ALLOWED=NO   CODE_SIGNING_REQUIRED=NO   build

test -d "$APP"
test -s "$APP/Info.plist"
test -s "$APP/Madeira"

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
  shasum -a 256 SteamOS-iOS.ipa build-info.json > SHA256SUMS
)

echo "STEAMOS_IOS_CLEAN_APP_OK app=$APP ipa=$IPA build_info=$ARTIFACTS/build-info.json"
