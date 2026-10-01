# SteamIOS Hangover convergence

Date: 2026-09-30

SteamIOS is an iOS-hosted Windows gaming compatibility runtime.  It does not
boot Windows, Linux, QEMU or UTM and it does not stream games from another
machine.

## Shipping execution path

```text
official Windows Steam / game.exe
        |
        v
Wine ARM64EC + WoW64
        |
        +-- x86-64 -> libarm64ecfex.dll -> FEX -> ARM64
        |
        +-- x86    -> libwow64fex.dll   -> FEX -> ARM64
        |
        v
native iOS host services
        |
        +-- D3D9/10/11 -> DXMT -> Metal
        +-- D3D12 -> Madeira D3D12 -> Metal
        +-- WASAPI/MMDevAPI -> CoreAudio
        +-- GameController/touch/keyboard/mouse -> Windows input APIs
```

The current iOS forks remain the shipping source because they contain the
JIT-pool, guest-window, Mach-thread, pseudo-process, display, audio and other
host work stock Hangover does not contain.  Hangover is the upstream behavior
reference for the Wine/FEX CPU-module boundary.

## Source policy

- Hangover master: `56e385b7ff490edd281b288f420677093563560b`
- Hangover Wine ARM64EC reference: `3ea3a14941b6a122b892c84141ce9662c008081e`
- Hangover FEX ARM64EC reference: `fa556167d5a64ec7adb5503c2aa15b169c292cac`
- SteamIOS Wine: `4f5b19718f4de88ecc5cb0dc08b119497a67ba8f`
- SteamIOS FEX: `26859e184ad90f0e811d7f8bbd943a4b1573a2c3`
- DXMT: `a5e0cd3d41bf248fd1c030a2e1c515ba3522f4ef`

`runtime/runtime-lock.json` is authoritative for the full source set.

## Hangover CPU-module contract

The clean build applies `tools/patches/apply-hangover-wine.py` to the
materialized SteamIOS Wine source.  It preserves the iOS loader lifecycle while
adding Hangover-compatible selectors:

```text
HODLL64=libarm64ecfex.dll
HODLL=libwow64fex.dll
```

FEX builds both canonical Hangover names and legacy Madeira aliases:

```text
arm64ec-windows/libarm64ecfex.dll
arm64ec-windows/xtajit64.dll

aarch64-windows/libwow64fex.dll
aarch64-windows/xtajit.dll
```

No interpreter fallback is allowed.  Both translators use the debugger-backed
SteamIOS RX/RW JIT pool.

## Windows compatibility profile

Wine defaults to its Windows 11 user-mode profile, reported as 10.0 build
26100.  This is API/registry compatibility only.  SteamIOS does not emulate the
Windows kernel, Windows desktop, TPM, Secure Boot or kernel drivers.

Kernel anti-cheat and kernel-driver-only software remain outside the supported
user-mode architecture.

## Graphics

Primary paths remain direct-to-Metal:

```text
D3D9/10/11 -> DXMT -> Metal
D3D12      -> Madeira D3D12 -> Metal
```

DXVK, VKD3D-Proton and MoltenVK are pinned in the runtime lock for optional
per-game fallback work.  They are intentionally not marked shipping until
their required Vulkan features pass on-device.  Optional fallback layers must
be lazy-loaded and must never lengthen normal Steam startup.

## Media and audio

Shipping audio remains:

```text
Windows WASAPI/MMDevAPI -> SteamIOS RemoteIO/CoreAudio
```

The runtime lock also pins FAudio, FFmpeg, GStreamer and dav1d as compatibility
sources.  They remain non-shipping until their iOS build and game tests pass;
the manifest must never claim otherwise.

## Bluetooth and physical controllers

Bluetooth/wired controllers are first-class native input:

```text
Bluetooth / wired controller
        -> Apple GameController
        -> GamepadInput
        -> WiniosGamepad
        -> XInput / DirectInput / HID / Windows.Gaming.Input
        -> Steam Input / game.exe
```

Physical controllers and the touch controller can coexist. SteamIOS starts
GameController wireless discovery, preserves four stable XInput slots, and
supports reconnect/hotplug. XInputSetState is carried back through win32u to
Core Haptics when the controller exposes haptics. GameController battery level
is surfaced through XInputGetBatteryInformation; unsupported battery chemistry
is reported as unknown rather than invented.

## Startup contract

The user never sees Wine, cmd.exe, a console, wineboot UI, or a black
transition.  A native Steam launch surface is immediate; the handoff occurs
only after verified Steam pixels arrive.

Warm launch is measured from app activation to the first **real interactive
Big Picture frame**, with a target of **3–5 seconds**.  First-time provisioning
and Steam client updates are measured separately.

Independent startup work must overlap:

- JIT verification / large FEX pool
- Metal/CAMetalLayer
- prefix readiness
- preinstalled Steam payload validation
- CoreAudio
- GameController

## Validation

Compilation is not completion.  The release gate requires x86 and x64 guest
execution, syscall/unixcall transitions, SEH/unwind, cross-thread context,
process/thread synchronization, Steam CEF multiprocess operation, login,
Steam Guard, library/download/install/PLAY, D3D11 and D3D12 presentation,
CoreAudio, physical Bluetooth controller/XInput, touch, game exit back to
Steam, a reusable prefix, hidden Wine internals and the 3–5 second warm
Big-Picture target.

`tools/verify-hangover-port.py` is the static CI discriminator. The clean app
workflow applies the Hangover Wine transform before restoring/building Wine
runtime artifacts and verifies the transformed source with `--materialized`.
`runtime/runtime-pack.json` records which Windows gaming dependencies are
actually shipping versus merely pinned candidates. Device tests remain
authoritative for behavioral and performance gates.
