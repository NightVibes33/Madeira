# Linux syscall acceptance ladder

The first fixture is deliberately syscall-minimal. The generated x86-64 ELF in `tests/elf/gen_static_smoke.py` uses only:

| x86-64 syscall | Number | Required result |
|---|---:|---|
| `write(1, "STEAMOS_IOS_ELF_OK\\n", 19)` | 1 | return 19 and publish exactly those bytes to guest stdout/log capture |
| `exit(0)` | 60 | terminate the guest execution context with status 0 |

The current Madeira `iOSSyscallHandler` already implements `write`, `exit`, and `exit_group`. The first on-device SteamOS-iOS Linux gate is therefore a regression/formalization test of an existing working seam, not a new syscall surface.

Next syscall families are added only after the static fixture is repeatable: `mmap/munmap/mprotect`, dynamic-loader file operations, TLS/thread primitives, futex, epoll/eventfd, sockets, shared memory, signals, and synthetic procfs support.
