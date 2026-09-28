# SteamOS-iOS Madeira baseline

Baseline frozen from the current Madeira upstream before SteamOS-iOS Linux-personality work.

## Source identity

| Component | Repository | Pinned revision |
|---|---|---|
| Madeira superproject | `willfaust/Madeira` | `9e8291eb42519b35b3d40b5f915c3a5f6d4fff45` |
| FEX | `willfaust/FEX` | `2838f3be52437620348264ada6c41042a9085290` |
| Wine | `willfaust/wine` (`madeira-lgpl`) | `8e3d23c77ceb903b59fdd8c123c867b7591490d5` |
| DXMT | `willfaust/dxmt` | `a5e0cd3d41bf248fd1c030a2e1c515ba3522f4ef` |
| rpmalloc (nested under FEX) | `willfaust/rpmalloc` | `812c2b9cf4310ffacf14e6b64066e78ab0c394b5` |

The `steamos-ios` development branch and the `baseline-madeira-ios` freeze branch were both created from the exact Madeira superproject commit above. The freeze branch must not receive SteamOS-iOS changes.

## Licensing snapshot

- Madeira application/original project code: GPL-3.0-or-later, with the repository's adopted Madeira Converter Exception where applicable.
- FEX upstream: MIT. Madeira-authored modifications in the pinned fork: GPL-3.0-or-later, with the recorded converter exception where applicable.
- Wine pinned fork branch `madeira-lgpl`: LGPL-2.1-or-later. Do not substitute the retired GPL-converted Wine branch.
- DXMT upstream portions: MIT. The imported D3D9/DXSO material recorded by the fork is LGPL-2.1-or-later. Madeira-authored modifications are GPL-3.0-or-later, with the recorded exception where applicable.
- rpmalloc upstream/Ryan Houdek material: 0BSD. Madeira-authored changes in the `ios-madeira` line are GPL-3.0-or-later, with the recorded exception where applicable.
- GnuTLS/Nettle/Hogweed/GMP and other bundled dependencies retain the licenses documented by upstream `THIRD-PARTY-NOTICES.md` and `docs/LICENSING.md`.
- Microsoft VC runtime files are not source-controlled here and must not be reconstructed or redistributed outside Microsoft's applicable redistribution terms.

This file records engineering provenance; the exact license texts and attribution files in the pinned repositories remain authoritative.

## Baseline implementation facts that must be preserved

The pinned Madeira baseline already contains:

- FEX x86-64 -> ARM64 JIT integration for iOS.
- debugger-assisted executable JIT mapping on current iOS builds.
- Wine ARM64EC integration and in-process/pseudo-process work.
- DXMT D3D10/11 -> Metal support.
- a minimal x86-64 Linux static ELF path inside `app/Madeira/FEXBridge.mm`, including ELF64/PT_LOAD mapping plus Linux `write`, `exit`, and `exit_group` syscall handling.
- substantial native Madeira D3D12 -> Metal work under `research/madeira-d3d12` and the associated runtime path. This is working upstream-derived infrastructure and must be evaluated before introducing a second D3D12 stack.
- Steam/CEF bring-up work that remains useful as a regression reference even though SteamOS-iOS will add a Linux-client execution plane.

## Clean-clone build state at freeze

The source records enough information to reconstruct the development build, but the baseline is not a one-command hermetic clean clone. The following are material build prerequisites/gaps at this freeze:

1. `toolchains/llvm-mingw-20260421-ucrt-macos-universal/` is external and must be fetched at the hash recorded by Madeira.
2. DXMT's native archive needs an iOS-target LLVM build under `toolchains/llvm-ios-build/` plus its source tree.
3. `build/dxmt-ios/build.sh` refreshes `libdxmt_combined.a` only when a combined archive already exists; clean CI must create the initial combined archive from DXMT objects plus the iOS LLVM archives.
4. `build/wineserver/build.sh` expects a pre-existing base `libwineserver.a`; clean CI must generate that base from the pinned Wine server sources before applying Madeira replacements.
5. Wine unix-side build scripts depend on generated files under `wine/build-macos/`; clean CI must configure/generate that build tree deterministically.
6. `research/freetype` is an external source checkout required by the current freetype build script.
7. `app/Madeira/x86_64-vcruntime/` is intentionally untracked and should not be fabricated by CI. A baseline build may create an empty resource directory for packaging validation, but full Windows-title compatibility requires legitimately supplied runtime files where needed.

SteamOS-iOS CI must fail with a named missing prerequisite rather than silently using stale developer-machine products.

## Baseline acceptance record

A baseline is considered frozen only when these are captured per run:

- superproject + recursive submodule revisions;
- Xcode/SDK version;
- IPA SHA-256;
- bundle identifier and executable;
- JIT ready/failure state;
- FEX x86-64 smoke result;
- Metal visible-frame result;
- known Madeira title regression state;
- device/iOS build, peak memory, and frame trace for on-device runs.
