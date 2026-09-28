# Linux syscall tests

The L0 dispatcher is the explicit boundary between FEX and the Linux personality.

Current deterministic contract:

- x86-64 Linux syscall 1: `write`
- x86-64 Linux syscall 60: `exit`
- x86-64 Linux syscall 231: `exit_group`
- unknown syscall: missing-syscall callback + `-ENOSYS`
- malformed dispatcher invocation: `-EINVAL`

Run `bash tests/linux-syscalls/run.sh`.

The host test proves argument routing and Linux return semantics. The on-device discriminator remains stronger: the x86-64 fixture must execute through FEX JIT, write `STEAMOS_IOS_ELF_OK\n`, and exit 0.
