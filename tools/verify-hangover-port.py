#!/usr/bin/env python3
"""Fail-closed checks for the SteamIOS Hangover convergence contract."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess

R = Path(__file__).resolve().parents[1]


def need(path: str, *needles: str) -> None:
    text = (R / path).read_text()
    for needle in needles:
        if needle not in text:
            raise SystemExit(f"HANGOVER_PORT_FAIL {path}: missing {needle}")


def exists(path: str) -> None:
    if not (R / path).exists():
        raise SystemExit(f"HANGOVER_PORT_FAIL missing {path}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--materialized", action="store_true",
                        help="also verify transformed Wine/FEX source after submodule checkout")
    args = parser.parse_args()

    lock = json.loads((R / "runtime/runtime-lock.json").read_text())
    pack = json.loads((R / "runtime/runtime-pack.json").read_text())

    assert lock["constraints"]["vm"] is False
    assert lock["constraints"]["remote_streaming"] is False
    assert lock["constraints"]["qemu"] is False
    assert lock["constraints"]["box64_shipping"] is False
    assert lock["constraints"]["cpu_translator"] == "FEX"
    assert lock["translator_contract"]["x64"]["selector"] == "HODLL64"
    assert lock["translator_contract"]["x86"]["selector"] == "HODLL"
    assert lock["input"]["bluetooth_controllers"] is True
    assert "CoreHaptics" in lock["input"]["windows_rumble"]
    assert "XInputGetBatteryInformation" in lock["input"]["battery_telemetry"]

    need("tools/patches/apply-hangover-wine.py",
         "STEAMIOS_HANGOVER_PORT_V1", "STEAMIOS_GAMEPAD_TELEMETRY_V1",
         "STEAMIOS_LOADER_NOTIFY_DEDUP_V1", "ml1145 SKIP duplicate loader registration",
         "STEAMIOS_TLS_INDEX_POOL_SYNC_V1", "[tls-sync] ml1147",
         "HODLL64", "HODLL", "libarm64ecfex.dll", "libwow64fex.dll",
         "VersionData[WIN11]", "Windows 11 Pro", "26100",
         "NtUserGamepadOp_Vibration", "NtUserGamepadOp_Battery")
    need("build/fex-arm64ec/build.sh",
         "libarm64ecfex.dll", "xtajit64.dll", "STEAMOS_HANGOVER_FEX64_OK",
         "FEX_IOS_HOST_BUILD=ON", "-DFEX_IOS_HOST")
    need("build/fex-wow64/build.sh",
         "libwow64fex.dll", "xtajit.dll", "STEAMOS_HANGOVER_FEX32_OK",
         "FEX_IOS_HOST_BUILD=ON", "-DFEX_IOS_HOST")
    need("build/steamos-ios/build-clean-app.sh",
         "apply-hangover-wine.py", "libarm64ecfex.dll", "libwow64fex.dll",
         "runtime/runtime-lock.json", "runtime/runtime-pack.json",
         "STEAMOS_HANGOVER_RUNTIME_OK")
    need("app/Madeira/WineProcessBridge.m",
         'setenv("HODLL64", "libarm64ecfex.dll", 1)',
         'setenv("HODLL", "libwow64fex.dll", 1)',
         "WINE_IOS_JIT_RX", "WINE_IOS_JIT_RW", "WINE_IOS_JIT_SIZE",
         "AVAudioSessionCategoryPlayback", "madeira_apply_windows11_profile",
         ".steamios-runtime-ready-v2", '\\"Version\\"=\\"win11\\"')
    need("app/Madeira/ContentView.swift",
         "[boot-budget]", "STEAMIOS_WARM_BOOT_TARGET_MS",
         "STEAMIOS_RUNTIME_PROFILE", "first verified Big Picture frame",
         'setenv("MADEIRA_INPROC_SYNC", "0", 1)',
         'setenv("MADEIRA_FASTSYNC", "0", 1)',
         'setenv("MADEIRA_IMAGE_MAP_GUARD", "1", 1)')
    need("app/Madeira/GamepadInput.swift",
         "GCController.startWirelessControllerDiscovery", "wireless/Bluetooth",
         "SteamIOSControllerHaptics", "CoreHaptics", "battery.batteryLevel",
         "winios_gamepad_get_vibration")
    need("app/Madeira/Winios/WiniosGamepad.h",
         "winios_vibration", "battery_type", "battery_level", "has_haptics")
    need("app/Madeira/Winios/WiniosGamepad.c",
         "winios_gamepad_set_vibration", "winios_gamepad_get_vibration")
    if "next.reserved" in (R / "app/Madeira/Winios/WiniosGamepad.c").read_text():
        raise SystemExit("HANGOVER_PORT_FAIL stale reserved-field access in WiniosGamepad.c")
    need("build/win32u-unix/driver_ios.c",
         "NtUserGamepadOp_Vibration", "NtUserGamepadOp_Battery",
         "XINPUT_CAPS_FFB_SUPPORTED")
    need("build/ntdll-unix/audio_null_ios.c", "AudioUnit", "RemoteIO")
    need("docs/STEAMOS_IOS_ARCHITECTURE.md", "Hangover", "HODLL64", "Bluetooth", "3–5")
    need("docs/CONTROLLERS.md", "Bluetooth/wireless", "Core Haptics",
         "XInputGetBatteryInformation")

    workflow = (R / ".github/workflows/steamos-ios-app.yml").read_text()
    overlay_pos = workflow.find('apply-hangover-wine.py')
    wine_build_pos = workflow.find("Configure Wine host headers")
    if overlay_pos < 0 or wine_build_pos < 0 or overlay_pos > wine_build_pos:
        raise SystemExit("HANGOVER_PORT_FAIL app workflow must transform Wine before any Wine build")
    for cache_tag in (
        "steamios-native-deps-xcode27-v1",
        "steamios-fex-xcode27-v1",
        "steamios-i386-farm-xcode27-v3",
        "steamios-wine-runtime-xcode27-v1",
        "steamios-llvm-ios-xcode27-v1",
        "steamios-dxmt-ios-xcode27-v1",
        # Retained only as the one-time migration source for the split caches.
        "steamios-runtime-xcode27-v5",
    ):
        if cache_tag not in workflow:
            raise SystemExit(f"HANGOVER_PORT_FAIL cache discriminator missing: {cache_tag}")

    expected = {
        "FEX": "26859e184ad90f0e811d7f8bbd943a4b1573a2c3",
        "wine": "4f5b19718f4de88ecc5cb0dc08b119497a67ba8f",
        "research/dxmt": "a5e0cd3d41bf248fd1c030a2e1c515ba3522f4ef",
    }
    for path, sha in expected.items():
        line = subprocess.check_output(["git", "ls-tree", "HEAD", "--", path], cwd=R, text=True).strip()
        actual = line.split()[2]
        if actual != sha:
            raise SystemExit(f"HANGOVER_PORT_FAIL pin {path}: {actual} != {sha}")

    optional = (
        "dxvk", "vkd3d_proton", "moltenvk", "faudio", "ffmpeg", "gstreamer",
        "dav1d", "wine_mono", "openal_soft", "cnc_ddraw",
    )
    for name in optional:
        if lock["sources"][name]["shipped"]:
            raise SystemExit(
                f"HANGOVER_PORT_FAIL {name}: optional stack may not be marked shipped without device certification"
            )

    for name in ("faudio", "openal_soft", "wine_mono", "ffmpeg", "gstreamer",
                 "dav1d", "dxvk", "vkd3d_proton", "moltenvk", "cnc_ddraw"):
        if pack["candidates"][name]["status"] != "pinned-not-shipping":
            raise SystemExit(f"HANGOVER_PORT_FAIL runtime pack candidate state: {name}")

    if args.materialized:
        need("wine/dlls/ntdll/loader.c",
             "STEAMIOS_HANGOVER_PORT_V1", "HODLL64", "libarm64ecfex.dll",
             "STEAMIOS_TLS_INDEX_POOL_SYNC_V1", "[tls-sync] ml1147")
        need("wine/dlls/wow64/syscall.c",
             "STEAMIOS_HANGOVER_PORT_V1", "HODLL", "libwow64fex.dll")
        need("wine/dlls/ntdll/version.c", "VersionData[WIN11]", "10, 0, 26100")
        need("wine/dlls/ntdll/signal_arm64ec.c",
             "MADEIRA_IMAGE_MAP_GUARD", "STEAMIOS_LOADER_NOTIFY_DEDUP_V1",
             "ml1145 SKIP duplicate loader registration", "pNotifyImageMap")
        need("wine/loader/wine.inf.in", "Windows 11 Pro", "26100")
        need("wine/include/ntuser.h",
             "STEAMIOS_GAMEPAD_TELEMETRY_V1",
             "NtUserGamepadOp_Vibration", "NtUserGamepadOp_Battery")
        need("wine/dlls/xinput1_3/main.c",
             "STEAMIOS_GAMEPAD_TELEMETRY_V1",
             "NtUserGamepadOp_Vibration", "NtUserGamepadOp_Battery")
        exists("FEX/Source/Windows/ARM64EC/IosJitAlias.cpp")
        exists("FEX/Source/Windows/WOW64/IosMonoBridge.cpp")
        need("FEX/Source/Windows/ARM64EC/CMakeLists.txt", "FEX_IOS_HOST_BUILD")
        need("FEX/Source/Windows/WOW64/CMakeLists.txt", "FEX_IOS_HOST_BUILD")

    print("STEAMOS_HANGOVER_PORT_STATIC_OK" + (" materialized=1" if args.materialized else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())