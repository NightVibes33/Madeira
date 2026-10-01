#!/usr/bin/env python3
from pathlib import Path
import sys

OLD = "bool InvalidationTracker::ProtectRWXIntervalsInternal(uint64_t Address, uint64_t Size, bool ForWriteLocked) {\n  const auto End = Address + Size;\n  std::shared_lock Lock(IntervalsLock);\n\n  if (SMCDetectionDisabled) {\n    return false;\n  }\n\n  bool HitRWXInterval = false;\n  do {\n    const auto Query = RWXIntervals.Query(Address);\n    if (Query.Enclosed) {\n      if (!HitRWXInterval) {\n        if (ForWriteLocked) {\n          // If we are protecting as writable, then the entire range must be invalidated before any protections are\n          // applied and the invalidation mutex must be locked throughout.\n          // Do this lazily only when an RWX region is actually hit.\n          // NOTE: This assumes CodeInvalidationMutex is locked by the caller\n          InvalidateIntervalInternalLocked(Address, Size);\n        }\n        HitRWXInterval = true;\n      }\n      void* TmpAddress = reinterpret_cast<void*>(Address);\n      SIZE_T TmpSize = static_cast<SIZE_T>(std::min(End, Address + Query.Size) - Address);\n      ULONG TmpProt;\n      NtProtectVirtualMemory(NtCurrentProcess(), &TmpAddress, &TmpSize, ForWriteLocked ? GetUntrapProt(Address) : GetTrapProt(Address), &TmpProt);\n    } else if (!Query.Size) {\n      // No more regions past `Address` in the interval list\n      break;\n    }\n\n    Address += Query.Size;\n  } while (Address < End);\n\n  return HitRWXInterval;\n}"
NEW = "bool InvalidationTracker::ProtectRWXIntervalsInternal(uint64_t Address, uint64_t Size, bool ForWriteLocked) {\n  /* iOS-Madeira ml1140: NEVER call NtProtectVirtualMemory while holding\n   * IntervalsLock.\n   *\n   * On iOS/Wine, NtProtectVirtualMemory synchronously feeds the protection\n   * change back through BTCpuNotifyMemoryProtect ->\n   * HandleMemoryProtectionNotification(), which needs IntervalsLock\n   * exclusively. Holding a shared lock here therefore self-deadlocks Steam's\n   * first ARM64EC/FEX thread in os_sync_wait_on_address.\n   *\n   * Query one interval while locked, release the lock, apply protection, then\n   * re-query. This also avoids carrying stale interval iterators across a\n   * synchronous protection callback. */\n  const auto End = Address + Size;\n  const auto Begin = Address;\n\n  bool HitRWXInterval = false;\n  bool InvalidatedForWrite = false;\n  while (Address < End) {\n    uint64_t Advance = 0;\n    SIZE_T ProtectSize = 0;\n    ULONG NewProtection = 0;\n\n    {\n      std::shared_lock Lock(IntervalsLock);\n      if (SMCDetectionDisabled) {\n        return HitRWXInterval;\n      }\n\n      const auto Query = RWXIntervals.Query(Address);\n      if (Query.Enclosed) {\n        HitRWXInterval = true;\n        ProtectSize = static_cast<SIZE_T>(std::min<uint64_t>(End - Address, Query.Size));\n        Advance = ProtectSize;\n        NewProtection = ForWriteLocked ? GetUntrapProt(Address) : GetTrapProt(Address);\n      } else if (!Query.Size) {\n        break;\n      } else {\n        Advance = std::min<uint64_t>(End - Address, Query.Size);\n      }\n    } // IntervalsLock released before any Wine protection callback.\n\n    if (ProtectSize) {\n      if (ForWriteLocked && !InvalidatedForWrite) {\n        // Caller owns CodeInvalidationMutex on this path.\n        InvalidateIntervalInternalLocked(Begin, Size);\n        InvalidatedForWrite = true;\n      }\n\n      void* TmpAddress = reinterpret_cast<void*>(Address);\n      SIZE_T TmpSize = ProtectSize;\n      ULONG TmpProt;\n      const auto Status =\n        NtProtectVirtualMemory(NtCurrentProcess(), &TmpAddress, &TmpSize, NewProtection, &TmpProt);\n#ifdef FEX_IOS_HOST\n      static std::atomic<uint32_t> IOSUnlockedProtectCount {0};\n      const auto N = IOSUnlockedProtectCount.fetch_add(1, std::memory_order_relaxed) + 1;\n      if (N <= 8) {\n        LogMan::Msg::EFmt(\n          \"[iOS-xlock] ml1140 #{} protect={:#x}+{:#x} new={:#x} status={:#x} lock=RELEASED\",\n          N, Address, ProtectSize, NewProtection, static_cast<uint32_t>(Status));\n      }\n#endif\n    }\n\n    if (!Advance) {\n      break;\n    }\n    Address += Advance;\n  }\n\n  return HitRWXInterval;\n}"

if len(sys.argv) != 2:
    raise SystemExit("usage: apply-fex-invalidation-lock.py <InvalidationTracker.cpp>")

path = Path(sys.argv[1])
text = path.read_text()

if "ml1140: NEVER call NtProtectVirtualMemory while holding" in text:
    print("FEX_IOS_INTERVAL_LOCK_PATCH_ALREADY_APPLIED")
    raise SystemExit(0)

count = text.count(OLD)
if count != 1:
    raise SystemExit(
        f"FEX_IOS_INTERVAL_LOCK_PATCH_REFUSED expected exact pinned function once, found {count}"
    )

path.write_text(text.replace(OLD, NEW))
check = path.read_text()
if "[iOS-xlock] ml1140" not in check or "IntervalsLock released before" not in check:
    raise SystemExit("FEX_IOS_INTERVAL_LOCK_PATCH_VERIFY_FAILED")

print("FEX_IOS_INTERVAL_LOCK_PATCH_OK")
