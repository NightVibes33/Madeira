# SteamOS-iOS architecture

## Product boundary

SteamOS-iOS is a sideloadable iOS application that runs supported PC software locally through user-mode compatibility and dynamic binary translation. iOS/XNU remains the only kernel. The project does not boot a Linux or Windows kernel and does not use a full-system VM, remote PC, cloud renderer, or Steam Link as its execution engine.

The target data path is:

```text
iOS/XNU
  + native host: UIKit/SwiftUI, CAMetalLayer, GameController, CoreAudio
  + SteamOS-iOS Linux personality
  + FEX x86/x86-64 -> ARM64 JIT
  + real Steam Linux userland
  + SteamOS-iOS Steam Play tool
      + Madeira-derived Wine/Proton runtime
      + DXMT for D3D10/11
      + Madeira native D3D12/Metal path where compatible
      + optional VKD3D/Vulkan/Metal path only when capability work proves value
  -> Metal -> display
```

## Foundation rule

The frozen starting point is `docs/STEAMOS_IOS_BASELINE.md`. Working Madeira paths are regression constraints, not disposable prototypes. New Linux-personality work is additive until equivalent tests prove a replacement.

A key baseline fact is that Madeira already executes a small x86-64 Linux static ELF through FEX in `FEXBridge.mm`. SteamOS-iOS extracts and hardens that seam rather than inventing a second loader.

A second key baseline fact is that current Madeira contains a native D3D12-to-Metal implementation under `research/madeira-d3d12`. The original handoff's VKD3D-Proton -> MoltenVK plan remains a possible compatibility backend, but it is no longer the automatic first D3D12 route. The proven Madeira D3D12 implementation must be benchmarked and capability-tested first. No working D3D11 or D3D12 path is removed merely to make the architecture diagram cleaner.

## Execution planes

### Plane A: real Steam Linux client

```text
x86-64 Steam ELF
  -> ELF loader / Linux process abstraction
  -> FEX JIT
  -> Linux syscall/personality layer
  -> Darwin/Mach/native iOS services
```

Milestones are strict: static ELF, dynamic ELF, pthread/TLS, filesystem, socket/TLS, event primitives, shared memory/process behavior, CEF stress harness, then Steam bootstrap. Steam is not used to debug an unproven syscall layer.

### Plane B: Windows Steam Play titles

Steam registers an iOS-specific compatibility tool. A launch context contains the appid, executable, working directory, args, environment, compatdata path, renderer selection, and input profile. The compatibility tool enters the Madeira-derived Wine/FEX runtime and presents through Metal.

Per-title state belongs under a distinct compatibility-data directory. Game prefixes are never globally merged.

## Linux personality modules

`runtime/linux/` owns the Linux-facing contract. Initial modules are:

- `elf/`: ELF64 validation and load planning.
- `process/`: guest PID/TID, thread, FD table, environment, CWD, wait/exit, signals.
- `syscalls/`: Linux syscall ABI dispatch and Linux errno semantics.
- `vfs/`: normalized virtual paths and sandbox-approved host mappings.
- `futex/`: Linux futex semantics over appropriate Darwin synchronization primitives.
- `epoll/`: epoll/eventfd/timerfd compatibility over kqueue/managed objects.
- `shm/`: guest shared-memory objects backed by host-safe mappings.
- `procfs`, `sysfs`, `devfs`: synthetic nodes generated only as required.
- `networking`: Linux socket ABI translation to Darwin BSD sockets.

The loader/parser must reject malformed bounds, overflows, unsupported class/endian/machine/type combinations, and entry points outside executable load segments before mapping guest memory.

## First new-code gate

The generated fixture in `tests/elf/gen_static_smoke.py` is a deterministic static x86-64 Linux ELF. Its complete behavior is:

```text
write(1, "STEAMOS_IOS_ELF_OK\n", 19)
exit(0)
```

Gate L0 is only green when the target device proves:

```text
fixture ELF
  -> SteamOS-iOS ELF validation/load plan
  -> FEX JIT
  -> Linux syscall bridge
  -> exact output STEAMOS_IOS_ELF_OK\n
  -> exit status 0
```

No QEMU, VM, remote execution, interpreter fallback, or host-native replacement binary is acceptable evidence.

The host-side parser/generator test is necessary CI coverage but does not by itself satisfy L0. L0 requires an on-device FEX execution log/diagnostic discriminator.

## JIT invariant

Guest execution is gated on JIT readiness. Failure to obtain the currently supported executable mapping mechanism produces an explicit `unavailable`/`faulted` state and disables Play. SteamOS-iOS never silently substitutes a slow interpreter while reporting a healthy runtime.

Runtime telemetry must expose reserved executable capacity, RW/RX views, code-cache use, translation/invalidation counts, guest VA reservations, peak memory, and memory-pressure events.

## Process model

Desktop fork/exec semantics cannot be assumed. Guest processes are logical runtime objects inside the host task unless a future supported iOS mechanism provides a better primitive. Each logical process still needs independent PID identity, FD table semantics, environment, CWD, signal state, wait status, pipes/sockets, shared memory, and structured logs.

A recoverable guest exception must become a guest/game crash record rather than an intentional host-app termination. Because all work shares the host task, memory-corruption containment is a design requirement, not an afterthought.

## VFS boundary

Guest absolute paths never become host absolute paths directly:

```text
guest path
 -> Linux normalization
 -> virtual mount lookup
 -> symlink/escape validation
 -> sandbox-approved host URL/path
```

Tests must cover `..`, absolute symlinks, symlink loops, Unicode normalization, case behavior, locking, mmap/truncate races, and concurrent access.

## Graphics policy

- D3D10/11: preserve DXMT -> Metal as the preferred path.
- D3D12: preserve and profile Madeira's existing native D3D12 -> Metal implementation. Add a capability JSON gate and standalone D3D12 microtests before claiming title support.
- VKD3D-Proton/MoltenVK: optional second backend. It is accepted only after exact target-device descriptor/synchronization/format limits are measured; capabilities are never fabricated.
- Native Vulkan guests: thunk to an adapted native Vulkan/Metal backend when safe rather than translating every call through x86.
- Final presentation belongs to a native `CAMetalLayer`; touch controls are native overlays, not pixels drawn into the guest render target.

D3D12 acceptance remains incremental: DLL load, device, queue, allocator/list, descriptor heap, root signature, resources, PSO, clear, triangle, texture, depth, compute, synchronization/descriptor stress, sustained present, then a real title.

## Input/audio policy

All physical and touch inputs normalize into one `VirtualControllerState`, then fan out to XInput/HID/DirectInput or Linux evdev/hidraw/SDL-facing abstractions. Hotplug and simultaneous touch combinations are first-class tests.

Audio enters native CoreAudio/AVAudioSession through thin compatibility bridges. A large Linux desktop audio stack is not a dependency unless measured compatibility requires it.

## Performance evidence

Every title claim includes device, iOS build, internal resolution, renderer, cache state, frame-time data, memory, and thermal duration. Base iPhone 16 presentation is capped by its 60-Hz display; 120-FPS certification is only meaningful on 120-Hz hardware with <=8.33 ms sustained frame time.

No menu screenshot or short burst is a compatibility/performance certification.

## Stop gates

Do not proceed to real Steam bootstrap until static ELF execution is repeatable. Do not proceed to polished Game Mode UI until the real Steam library is populated. Do not broaden D3D12 title testing until the standalone D3D12 ladder is deterministic. Do not introduce anti-cheat or DRM bypass work.
