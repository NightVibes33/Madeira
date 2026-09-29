#!/usr/bin/env python3
from __future__ import annotations

import pathlib
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: apply-fex-ios-native-host.py <FEX checkout>")

root = pathlib.Path(sys.argv[1]).resolve()
path = root / "FEXCore/Source/Utils/ArchHelpers/Arm64.cpp"
allocator_path = root / "FEXCore/Source/Utils/AllocatorHooks.cpp"
text = path.read_text()

old = r'''  MEMORY_BASIC_INFORMATION mbi {};
  const char* type = "?";
  if (VirtualQuery(reinterpret_cast<LPCVOID>(GPRs[AddressReg]), &mbi, sizeof(mbi))) {
    type = mbi.Type == MEM_IMAGE ? "MEM_IMAGE" : mbi.Type == MEM_MAPPED ? "MEM_MAPPED" : "MEM_PRIVATE";
  }
  LogMan::Msg::EFmt("[caspal128] MISALIGNED-UNSUPPORTED Size={} addrReg=x{} addr={:#x} misalign={} "
                    "crosses16B={} | region base={} size={:#x} prot={:#x} type={} state={:#x}",
                    Size, AddressReg, GPRs[AddressReg], GPRs[AddressReg] & 15,
                    (GPRs[AddressReg] & 15) ? "yes" : "no", mbi.BaseAddress, mbi.RegionSize,
                    mbi.Protect, type, mbi.State);
'''

new = r'''#if defined(_WIN32)
  MEMORY_BASIC_INFORMATION mbi {};
  const char* type = "?";
  if (VirtualQuery(reinterpret_cast<LPCVOID>(GPRs[AddressReg]), &mbi, sizeof(mbi))) {
    type = mbi.Type == MEM_IMAGE ? "MEM_IMAGE" : mbi.Type == MEM_MAPPED ? "MEM_MAPPED" : "MEM_PRIVATE";
  }
  LogMan::Msg::EFmt("[caspal128] MISALIGNED-UNSUPPORTED Size={} addrReg=x{} addr={:#x} misalign={} "
                    "crosses16B={} | region base={} size={:#x} prot={:#x} type={} state={:#x}",
                    Size, AddressReg, GPRs[AddressReg], GPRs[AddressReg] & 15,
                    (GPRs[AddressReg] & 15) ? "yes" : "no", mbi.BaseAddress, mbi.RegionSize,
                    mbi.Protect, type, mbi.State);
#else
  LogMan::Msg::EFmt("[caspal128] MISALIGNED-UNSUPPORTED Size={} addrReg=x{} addr={:#x} misalign={} "
                    "crosses16B={} | native-host region metadata unavailable",
                    Size, AddressReg, GPRs[AddressReg], GPRs[AddressReg] & 15,
                    (GPRs[AddressReg] & 15) ? "yes" : "no");
#endif
'''

if new in text:
    print(f"FEX_IOS_PATCH_OK already-applied={path}")
    raise SystemExit(0)

count = text.count(old)
if count != 1:
    raise SystemExit(
        f"error: pinned FEX source drift around CASPAL diagnostics: "
        f"expected one exact block, found {count}"
    )

text = text.replace(old, new, 1)

path.write_text(text)

allocator_text = allocator_path.read_text()
allocator_bad = """#else
void InitializeThread() {}

void* malloc(size_t size) {
  return ::malloc(size);
}"""
if allocator_bad not in allocator_text:
    raise SystemExit("error: pinned FEX allocator-disabled branch anchor drifted")

guard_bad = """size_t malloc_usable_size(void* ptr) {
  IOS_RPM_GUARD();
#ifdef __APPLE__
  return ::malloc_size(ptr);"""
guard_good = """size_t malloc_usable_size(void* ptr) {
#ifdef __APPLE__
  return ::malloc_size(ptr);"""

if guard_good not in allocator_text:
    count = allocator_text.count(guard_bad)
    if count != 1:
        raise SystemExit(
            f"error: pinned FEX allocator-disabled IOS_RPM_GUARD drift: "
            f"expected one exact block, found {count}"
        )
    allocator_text = allocator_text.replace(guard_bad, guard_good, 1)
    allocator_path.write_text(allocator_text)

print(f"FEX_IOS_PATCH_OK applied={path} allocator={allocator_path}")
