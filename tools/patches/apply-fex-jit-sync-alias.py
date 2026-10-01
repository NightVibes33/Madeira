#!/usr/bin/env python3
from pathlib import Path
import sys

OLD = '''#include <processenv.h>
#include "../Priv.h"

WINBOOL WaitOnAddress(volatile void* Address, void* CompareAddress, SIZE_T AddressSize, DWORD dwMilliseconds) {
  LARGE_INTEGER Time;
  // A negative value indicates a relative time measured in 100ns intervals.
  Time.QuadPart = static_cast<ULONGLONG>(dwMilliseconds) * -10000;
  return RtlWaitOnAddress(const_cast<void*>(Address), CompareAddress, AddressSize, dwMilliseconds == INFINITE ? nullptr : &Time) == STATUS_SUCCESS;
}

void WakeByAddressAll(PVOID Address) {
  RtlWakeAddressAll(Address);
}

void WINAPI WakeByAddressSingle(PVOID Address) {
  RtlWakeAddressSingle(Address);
}
'''

NEW = '''#include <processenv.h>
#include "../Priv.h"

#if defined(FEX_IOS_HOST) && defined(ARCHITECTURE_arm64ec)
#include <FEXCore/Utils/DualMap.h>

/* SteamIOS ml1144: FEX's ARM64EC PE executes out of the JIT pool's RX alias.
 *
 * Data loads through that alias are coherent, but writes/atomics are deliberately
 * redirected to RX + DualMap::WriteOffset (the RW alias). Darwin's
 * os_sync_wait_on_address/__ulock wait queues are keyed by the virtual address,
 * not by the underlying memory object. Waiting on RX while the matching atomic
 * and wake operate on RW therefore loses the wake forever.
 *
 * IosJitReverseTranslate is a cheap membership test for a JIT-backed PE alias:
 * if it changes the address, the input is an RX alias and its writable
 * synchronization identity is Address + WriteOffset. Ordinary guest/stack/heap
 * addresses are returned unchanged.
 */
extern "C" uint64_t IosJitReverseTranslate(uint64_t Addr);

static inline void* IosCanonicalSyncAddress(void* Address) {
  const auto Addr = reinterpret_cast<uint64_t>(Address);
  if (!FEXCore::DualMap::WriteOffset) {
    return Address;
  }

  const auto Original = IosJitReverseTranslate(Addr);
  if (Original == Addr) {
    return Address;
  }

  return reinterpret_cast<void*>(Addr + FEXCore::DualMap::WriteOffset);
}
#else
static inline void* IosCanonicalSyncAddress(void* Address) {
  return Address;
}
#endif

WINBOOL WaitOnAddress(volatile void* Address, void* CompareAddress, SIZE_T AddressSize, DWORD dwMilliseconds) {
  LARGE_INTEGER Time;
  // A negative value indicates a relative time measured in 100ns intervals.
  Time.QuadPart = static_cast<ULONGLONG>(dwMilliseconds) * -10000;
  void* SyncAddress = IosCanonicalSyncAddress(const_cast<void*>(Address));
  return RtlWaitOnAddress(SyncAddress, CompareAddress, AddressSize, dwMilliseconds == INFINITE ? nullptr : &Time) == STATUS_SUCCESS;
}

void WakeByAddressAll(PVOID Address) {
  RtlWakeAddressAll(IosCanonicalSyncAddress(Address));
}

void WINAPI WakeByAddressSingle(PVOID Address) {
  RtlWakeAddressSingle(IosCanonicalSyncAddress(Address));
}
'''

if len(sys.argv) != 2:
    raise SystemExit("usage: apply-fex-jit-sync-alias.py <Sync.cpp>")

path = Path(sys.argv[1])
text = path.read_text()

if "SteamIOS ml1144" in text:
    print("FEX_IOS_JIT_SYNC_ALIAS_PATCH_ALREADY_APPLIED")
    raise SystemExit(0)

count = text.count(OLD)
if count != 1:
    raise SystemExit(
        f"FEX_IOS_JIT_SYNC_ALIAS_PATCH_REFUSED expected exact pinned block once, found {count}"
    )

path.write_text(text.replace(OLD, NEW))
check = path.read_text()
for needle in (
    "SteamIOS ml1144",
    "IosCanonicalSyncAddress",
    "IosJitReverseTranslate",
    "RtlWakeAddressSingle(IosCanonicalSyncAddress(Address))",
):
    if needle not in check:
        raise SystemExit(f"FEX_IOS_JIT_SYNC_ALIAS_PATCH_VERIFY_FAILED missing {needle}")

print("FEX_IOS_JIT_SYNC_ALIAS_PATCH_OK")
