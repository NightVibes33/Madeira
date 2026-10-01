# SteamOS-iOS architecture — Windows Steam first

Date: 2026-09-28  
Target: iPhone 16 / A18, iOS 27+, JIT enabled  
Artifact: sideloadable IPA  
Execution model: user-mode compatibility/runtime translation; not a full-system VM

## Product flow

```text
SteamOS-iOS.ipa
  -> native iOS host (SwiftUI/UIKit + CAMetalLayer + CoreAudio + GameController)
  -> JIT capability
  -> Madeira Wine ARM64EC / WoW64 runtime
  -> FEX x86/x86-64 -> ARM64 JIT
  -> official Windows Steam client
  -> Steam login / Steam Guard / library / downloads
  -> Steam launches owned Windows game locally
  -> D3D10/11 -> DXMT -> Metal
  -> D3D12 -> Madeira D3D12 path first; VKD3D-Proton/MoltenVK evaluated only where needed
  -> native presentation, audio, physical controller, touch controller
```

## Architectural cut

The active product does **not** implement a Linux Steam personality.

Removed from the active runtime contract:

- ELF/glibc compatibility for the Steam client
- synthetic Linux `/proc`
- Linux syscall emulation for Steam
- `clone3`, Linux futex, Linux epoll, Linux `/dev/input`
- a Linux Steam bootstrap
- a fake Proton registration layer whose only purpose is to make Steam believe it is on Linux

Git history retains the abandoned experiment; it is not compiled into the app.

## Frozen Madeira foundation

The Windows-first runtime preserves the 2026-09-28 Madeira integration baseline:

- Madeira superproject baseline: `9e8291eb42519b35b3d40b5f915c3a5f6d4fff45`
- FEX: `2838f3be52437620348264ada6c41042a9085290`
- Wine ARM64EC/WoW64: `8e3d23c77ceb903b59fdd8c123c867b7591490d5`
- DXMT: `a5e0cd3d41bf248fd1c030a2e1c515ba3522f4ef`
- in-process/pseudo-process Windows model
- debugger-assisted JIT allocation
- DXMT D3D10/11 -> Metal
- existing Steam/CEF bring-up and login-window work
- existing physical-controller and touch-controller plumbing
- existing Madeira native D3D12 research/runtime canaries

## First-run Steam bootstrap

The official Windows installer is downloaded at runtime from Valve:

`https://cdn.fastly.steamstatic.com/client/installer/SteamSetup.exe`

The installer is not bundled in the repository or IPA.

First run:

1. Verify JIT.
2. Ensure the app-owned Wine prefix exists.
3. Download `SteamSetup.exe` to `C:\SteamSetup.exe`.
4. Validate that the payload is nontrivial and begins with the PE `MZ` signature.
5. Launch it through Wine WoW64/FEX with `/S`.
6. Start Wine services.
7. Launch installed `steam.exe` in the same Madeira desktop session.
8. Keep CEF sandbox disabled because Chromium's native Windows sandbox cannot map directly onto this iOS/Wine process model.
9. Keep Steam CEF/V8 jitless until the runtime-x86 generation path is stable under FEX.

Subsequent runs bypass the installer and regenerate `C:\steam-launch.bat` before launching Steam.

## Execution paths

### Windows x64

```text
x64 PE -> Wine ARM64EC -> xtajit64/FEX -> ARM64 host code
```

### Windows x86

```text
x86 PE -> Wine WoW64 -> wow64/wow64win -> xtajit/FEX -> ARM64 host code
```

This is why the official 32-bit Steam bootstrapper is now usable; the old x64-only restriction is obsolete.

### D3D11

```text
game.exe -> d3d11/dxgi -> DXMT -> Metal -> CAMetalLayer
```

DXMT remains the primary graphics path for the first playable Steam title.

### D3D12

Do not replace working Madeira D3D12 infrastructure prematurely. The order is:

1. preserve the existing packaged `d3d12.dll` and x64 D3D12 canaries;
2. prove `D3D12CreateDevice`;
3. prove the existing D3D12 cube on-device;
4. identify the first real Steam D3D12 title's missing feature set;
5. only then integrate VKD3D-Proton/MoltenVK for coverage gaps, or advance a direct D12MT-style Metal path.

## Implementation order

1. Freeze Madeira baseline
2. Clean IPA build
3. JIT proof
4. FEX x64 proof
5. Wine ARM64EC proof
6. WoW64/x86 proof
7. DXMT proof
8. Official Steam first-run bootstrap
9. Steam/CEF stability
10. Steam login
11. Steam Guard
12. Steam library
13. Steam downloads
14. Install one lightweight Windows title
15. PLAY -> local game process
16. D3D11 -> DXMT -> Metal
17. Audio
18. Physical controller
19. Touch controller
20. Per-game controller profiles
21. D3D12 capability probe
22. D3D12CreateDevice
23. D3D12 triangle/cube
24. Real D3D12 Steam title
25. Shader/PSO cache
26. Frame pacing + dynamic resolution
27. Performance HUD
28. 30-minute thermal certification
29. Steam Deck-style native shell

## Hard gates

No later milestone may be called complete based only on compilation.

- JIT READY = the executable-memory probe actually ran generated ARM64 and returned 42.
- FEX READY = known x64 Windows guest returned the expected result.
- WINE READY = Windows PE created and ran inside the Madeira process model.
- STEAM READY = real Valve client rendered interactive CEF and authenticated.
- LIBRARY READY = account-owned library populated from the live client.
- DOWNLOAD READY = Steam downloaded an owned Windows title into app-owned storage.
- PLAY READY = Steam launched that title through the Madeira process path.
- GRAPHICS READY = game presented recurring Metal frames.
- CONTROLLER READY = physical controller controls the running title.
- EXIT READY = game exits cleanly back to Steam.


## iPhone / iPad presentation

The Windows guest renders to a performance-oriented logical desktop and the raw,
process-lifetime `CAMetalLayer` is aspect-fit into the current iOS/iPadOS
presentation area. UIKit does **not** stretch the guest and does not fight DXMT
over `CAMetalLayer.drawableSize`.

The default desktop is derived from the physical display aspect:

- **iPhone:** 720 logical pixels high; width = display aspect × 720, clamped
  to 1152...1600 and rounded to an 8-pixel boundary.
- **iPad:** 900 logical pixels high; width = display aspect × 900, clamped
  to 1024...1440 and rounded to an 8-pixel boundary.

Examples: a ~19.5:9 iPhone lands around 1560-1570×720; a classic 4:3 iPad lands
at 1200×900. The active values are exported as `MADEIRA_SCREEN_W/H`.

On full-screen landscape layouts, the game/Steam image is fitted inside the
window safe area so the Dynamic Island, rounded corners, and home-indicator
regions do not hide Windows UI. A different game resolution is still fitted
without distortion.

Touch input uses the exact same fitted rectangle and active guest dimensions,
so letterbox/pillarbox regions cannot skew pointer coordinates.

Touch controls, keyboard UI, performance HUD, and Steam Settings remain native
overlays. They are never baked into the guest render target.

DXMT/the D3D backend remains the sole owner of Metal drawable dimensions.
Swift/UIKit owns only the on-screen frame in points.


## Mandatory JIT + local Apple GPU

SteamOS-iOS does not have an interpreter/CPU-renderer fallback product mode.

Before Steam or any Windows game starts:

1. `jit_check_debugged()` must report executable JIT capability.
2. `jit_test_execute()` must actually execute generated ARM64 code and return
   the sentinel value `42`; a debugger flag by itself does not count as JIT READY.
3. the runtime must obtain a real `MTLDevice` from
   `MTLCreateSystemDefaultDevice()`;
4. Madeira's large pre-executable JIT pool must allocate successfully or Wine
   launch aborts;
5. FEX/xtajit translates x86/x64 CPU code into ARM64 code stored in executable
   memory supplied by that JIT path;
6. D3D10/11 uses DXMT -> Metal and D3D12 uses the retained Madeira D3D12 path
   (with later VKD3D/MoltenVK expansion only where measured);
7. the final drawable is presented by the local UIWindow-hosted
   `CAMetalLayer`.

The old Madeira remote-Metal research transport is forcibly disabled in the
SteamOS-iOS product launch path. No remote machine participates in graphics
execution.

Steam's CEF client UI currently keeps `-cef-disable-gpu` as a bring-up
stability flag. That only affects Chromium rendering inside the Steam client;
it is **not** the game renderer. Games must use the local Apple GPU through
DXMT/D3D12 -> Metal.


## Steam child launch identity

The Windows Steam client is authoritative for Steam-managed game identity.
SteamOS-iOS does **not** globally inject a fixed `SteamAppId`, `SteamGameId`,
or `SteamAppPath` into every Wine guest.

For normal product flow:

```text
Steam.exe
  -> Steam chooses appid/executable/arguments/environment
  -> Wine pseudo-process child
  -> FEX / graphics / audio / input bridges
```

Standalone regression buttons may supply a host-only
`MADEIRA_STEAM_APP_PATH` / `MADEIRA_STEAM_APP_ID` pair. Wine consumes that
override once and clears it so a later real Steam session cannot inherit the
test title's identity. The Thumper regression path uses this mechanism for
AppID 356400; the normal Steam client path does not.


### JIT pool ownership

SteamOS-iOS no longer links the old native Linux-ELF `FEXBridge.mm` smoke
runtime into the iOS application. FEX is used where the product needs it:
inside the rebuilt Windows `xtajit64.dll` and WoW64 `xtajit.dll` translators.

The large `StikJITHelper` pool is the executable pool used by Windows
Wine/FEX Steam/game execution. After creation, SteamOS-iOS publishes
`WINE_IOS_JIT_RX`, `WINE_IOS_JIT_RW`, and `WINE_IOS_JIT_SIZE`.
The pinned Windows FEX/xtajit code derives
`DualMap::WriteOffset = RW - RX` from those exact variables before core
initialization.


### Reproducible WoW64 payload

The repository intentionally tracks `app/Madeira/i386-windows/` empty.
Therefore a clean SteamOS-iOS IPA build must regenerate the PE32 runtime before
Xcode packages the app:

1. `build/fex-arm64ec/build.sh` rebuilds `xtajit64.dll` from pinned FEX.
2. `build/fex-wow64/build.sh` rebuilds the WoW64 `xtajit.dll` backend.
3. `build/wine-i386/build.sh` builds the full i386 Wine farm and i386 DXMT
   frontends from the pinned Wine/DXMT sources.
4. The i386 build fails if its import-closure scan reports unresolved imports.
5. The clean app build requires the key PE32 system DLLs plus a substantial
   generated farm before Xcode may package the IPA.

This is mandatory because Valve's official `SteamSetup.exe` is a 32-bit
Windows executable; an IPA containing only the 64-bit Wine/ARM64EC side is not
a valid Windows-Steam bootstrap.


### ARM64EC translator build invariant

A generic FEX ARM64EC DLL is not sufficient on iOS. The clean
`build/fex-arm64ec/build.sh` configure must set
`MINGW_TRIPLE=arm64ec-w64-mingw32`, `FEX_IOS_HOST_BUILD=ON`, and compile
C/C++/ASM with `FEX_IOS_HOST`.
The pinned FEX `Module.cpp` guards the iOS JIT-alias and real
`WINE_IOS_JIT_RW/RX` write-offset setup behind that define. CI therefore
rejects a clean-build script that can silently produce a non-iOS
`xtajit64.dll`.


### Production Steam environment

The ordinary Steam launch explicitly clears Madeira research probes before
starting Wine. IR capture, source-watch, surface/frame dumping, socket-wire
tracing, dead-release diagnostics, broad optimizer A/B flags, and related
instrumentation remain diagnostics-only and are not enabled by normal Steam
or game launches.

`MADEIRA_JITLESS=1` remains enabled specifically for Steam CEF/V8 stability.
It does not disable FEX dynamic translation; the executable JIT sentinel and
large StikJIT pool are still mandatory.


### ARM64EC compiler/runtime toolchain

The clean build pins llvm-mingw `20260922` (LLVM 23.1.2), archive SHA-256
`52e5f5a7b131021d0c39a37a38fa380a1da7885cd04bd61afd0cd4ecfb8bc1f3`.

This is a build-toolchain requirement, not a runtime architecture change.
llvm-mingw builds libc++ as an ARM64X/native-aarch64 runtime and ARM64EC code
must resolve that sysroot correctly. Before rebuilding `xtajit64.dll`,
`fetch-llvm-mingw.sh` statically links an ARM64EC C++ smoke using mutex,
shared-mutex, filesystem and thread APIs. A toolchain that cannot resolve those
libraries is rejected before the expensive FEX compile.


### Pinned-FEX LLVM 23 header fix

The pinned FEX revision predates an upstream header hygiene fix in
`FEXCore/Source/Common/StringConv.h`: it calls `std::strtoll` and
`std::strtoull` without directly including `<cstdlib>`. LLVM 23/libc++
correctly requires that declaration source. SteamOS-iOS carries the minimal
tracked patch `tools/patches/fex-llvm23-cstdlib.patch` and applies it
idempotently before either Windows FEX translator build. No FEX revision is
floated to `main`.


## Steam Settings: touchscreen + optional controller overlay

Input is split deliberately:

- **Full-screen Touch** is independent of the controller overlay and defaults ON.
- **Direct Touch** maps the finger through the same aspect-correct transform used
  by Metal presentation, so tapping a Steam control hits the corresponding
  Windows coordinate.
- **Mouse / Trackpad** preserves Madeira's relative mouse-look, absolute cursor,
  long-press drag, two-finger scrolling and right-click behavior.
- **Controller Overlay** defaults OFF and is enabled from the native
  `Steam Settings` panel.
- The overlay remains a separate transparent UIWindow. Only actual virtual
  controls consume touches; empty screen space falls through to the full-screen
  touch surface.
- Physical GameController input remains available whether or not the virtual
  overlay is enabled.
- The landscape settings gear remains reachable with the controller overlay off,
  so a user can enable/edit controls without rotating the device.

The current Windows direct-touch bridge is a single absolute primary pointer,
which is sufficient for Steam/desktop touch navigation. The virtual controller
itself remains true multi-touch so sticks/buttons/triggers can be held
simultaneously.


## Mobile product shell

The shipping root view is no longer Madeira's diagnostics launcher. App launch
immediately presents a black Steam surface and starts the product pipeline:

```text
launch
 -> JIT already ready? continue
 -> otherwise invoke StikDebug JIT flow
 -> executable JIT probe
 -> local MTLDevice gate
 -> first run: Valve SteamSetup.exe
 -> later runs: installed Steam
 -> real Steam UI becomes the first interactive product UI
```

The old diagnostic buttons remain source-level engineering tools but are not
reachable from the normal root view.

### Touch without controller overlay

Direct touchscreen is independent from the controller overlay and defaults ON.
Finger coordinates use the same aspect-fit transform as the Metal surface and
are sent to the Windows touch path. Disabling Direct Touch switches back to the
existing trackpad/mouse-look semantics for titles that need relative mouse.

### Optional on-screen controller

The controller overlay defaults OFF. A full default XInput layout is prebuilt
(LS/RS, D-pad, ABXY, LB/RB, LT/RT, View/Menu/Guide) so enabling it is immediately
usable rather than presenting an empty editor.

A three-finger tap opens the native **Steam Settings** sheet above Steam/game
content. That sheet owns:
- Direct touchscreen toggle
- On-screen controller toggle
- controller-layout editor entry
- software keyboard action

The overlay remains a separate transparent UIWindow. When settings and the
controller are both off it is click-through, so ordinary direct touch reaches
Steam with no permanent floating controls.


### Shipping mobile shell

The normal root UI auto-starts Steam; the Madeira diagnostic launcher remains
compiled only as an engineering surface and is not shown at product launch.

Mobile defaults:
- Full-screen touch: ON
- Direct Touch: ON
- Controller overlay: OFF
- Physical controllers: independent of the overlay
- Three-finger tap: opens Steam Settings with no permanent floating settings UI

Enabling the controller overlay exposes a prebuilt XInput layout immediately,
while the existing editor can drag, resize and remap controls.


### Controller layout v2

Layout persistence is versioned at v2. The shipped default contains exactly
one L3 and one R3 in addition to LS/RS and the rest of the XInput surface.
Older saved layouts receive missing L3/R3 once without replacing existing
positions or mappings.

Editing is transient and independent from the persistent **Show Controller
Overlay** setting. Resetting a layout also preserves that setting. The editor
owns touch only in landscape; portrait stays click-through so an invisible
overlay cannot trap Steam input.


## Hangover convergence — 2026-09-30

SteamIOS now treats Hangover as the upstream reference for the Windows CPU
translation boundary while retaining the iOS-specific Wine/FEX forks required
by the platform. The shipping source pins and upstream references are recorded
in `runtime/runtime-lock.json`.

The clean build applies a fail-closed source patch that adds Hangover-compatible
translator selectors:

```text
HODLL64=libarm64ecfex.dll
HODLL=libwow64fex.dll
```

Both canonical module names and the old Madeira aliases are packaged. FEX
remains mandatory and continues to use the StikDebug-backed RX/RW JIT pool and
the relocated WoW64 guest window.

Wine's default user-mode compatibility profile is Windows 11 build 26100.
This is a Win32/NT API identity; SteamIOS does not implement or boot a Windows
kernel, Windows desktop, TPM, Secure Boot, Hyper-V or kernel drivers.

Bluetooth and wired controllers remain native first-class input through Apple
GameController, then the existing SteamIOS/Winios bridge exposes controller
state to Windows XInput/DirectInput/HID/Windows.Gaming.Input. Touch input
remains independent and can be used simultaneously.

The normal user-visible path remains windowless: native Steam launch surface,
then an atomic handoff to the first verified Steam Big Picture frame. Wine,
cmd.exe, console windows and black startup transitions are not product UI.
The warm target remains **3–5 seconds to the first real Big Picture frame**.

DXMT and Madeira D3D12 remain the primary Metal paths. DXVK, VKD3D-Proton,
MoltenVK, FAudio, FFmpeg, GStreamer and dav1d are pinned as optional
compatibility sources but are not marked shipping until their iOS builds and
device feature tests pass. They must be lazy/per-game fallbacks and must not
increase ordinary Steam boot time.

See `docs/HANGOVER_PORT.md` for the complete convergence contract and
`tools/verify-hangover-port.py` for the CI discriminator.
