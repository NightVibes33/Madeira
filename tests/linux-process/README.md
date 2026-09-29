# Linux process bootstrap tests

This gate validates the x86-64 Linux initial userspace stack independently of FEX.

It proves:

- 16-byte-aligned initial RSP
- argc / argv / envp layout
- AT_PHDR / AT_PHENT / AT_PHNUM / AT_PAGESZ / AT_BASE / AT_ENTRY
- optional 16-byte AT_RANDOM payload
- AT_EXECFN points to argv[0]
- AT_NULL termination
- bounded strings, argument limits, small-stack rejection, and guest-address overflow rejection

Run:

```sh
bash tests/linux-process/run.sh
```
