# SteamOS-iOS Linux personality

This directory is the user-mode Linux ABI/personality hosted by iOS/XNU. It is **not** a Linux kernel and must never acquire a full-system VM dependency.

Bring-up order is intentionally narrow:

1. `elf/`: deterministic x86-64 ELF parsing/loading plan.
2. `syscalls/`: only syscalls proven necessary by progressively larger tests.
3. `process/`: managed guest PID/thread/FD/signal state backed by host threads and runtime objects.
4. `vfs/`: sandbox-contained Linux path namespace plus synthetic `/proc`, `/sys`, and `/dev`.
5. `futex/`, `epoll/`, `shm/`, `signals/`, `networking/`: Linux-visible semantics translated to Darwin primitives.

The existing Madeira `FEXBridge.mm` already proves a small x86-64 static ELF can be mapped and executed through FEX with Linux `write` and `exit` syscalls. New work must preserve that execution path while extracting it into testable components.

## Invariants

- x86/x86-64 code executes through FEX JIT; no QEMU-system/UTM/VM path.
- JIT failure disables guest execution; it does not silently fall back to an interpreter.
- Guest pointers and lengths are validated before host dereference.
- Linux paths are normalized through a VFS boundary before touching app-container storage.
- Unknown syscalls return Linux-style `-ENOSYS` and emit structured diagnostics.
- A guest failure should terminate the guest process abstraction rather than intentionally terminate the host app.
