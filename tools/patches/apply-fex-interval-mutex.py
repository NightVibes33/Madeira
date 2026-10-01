#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: apply-fex-interval-mutex.py <InvalidationTracker.h>")

path = Path(sys.argv[1])
text = path.read_text()

marker = "iOS-Madeira ml1141: re-entrant-safe interval RW lock"

if marker in text:
    print("FEX_IOS_INTERVAL_MUTEX_PATCH_ALREADY_APPLIED")
    raise SystemExit(0)

include_old = "#include <FEXCore/Utils/IntervalList.h>\n#include <FEXCore/HLE/SyscallHandler.h>\n"
include_new = "#include <FEXCore/Utils/IntervalList.h>\n#include <FEXCore/HLE/SyscallHandler.h>\n#include <FEXCore/Utils/WritePriorityMutex.h>\n"

field_old = "  std::shared_mutex IntervalsLock;\n"
field_new = """#ifdef FEX_IOS_HOST
  /* iOS-Madeira ml1141: re-entrant-safe interval RW lock.
   *
   * The device freeze at Steam startup was symbolicated to
   * InvalidationTracker + 0x38. With LLVM 23.1.2 libc++ on Win64 the two
   * IntervalList vectors occupy 0x30 bytes, std::shared_mutex starts at
   * +0x30, and +0x08 is __gate1_: the condition variable used by readers and
   * later writers once the writer bit is set.
   *
   * FEX's Windows/iOS invalidation paths can be re-entered synchronously by
   * exception/memory-notification machinery while the interrupted frame owns
   * an exclusive interval lock. The custom WritePriorityMutex already has the
   * iOS writer->shared self-grant needed for this exact pattern, and it emits
   * bounded owner/holder diagnostics instead of an opaque infinite gate wait.
   *
   * Keep stock std::shared_mutex everywhere else. */
  FEXCore::Utils::WritePriorityMutex::Mutex IntervalsLock;
#else
  std::shared_mutex IntervalsLock;
#endif
"""

if text.count(include_old) != 1:
    raise SystemExit(f"FEX_IOS_INTERVAL_MUTEX_PATCH_REFUSED include match count={text.count(include_old)}")
if text.count(field_old) != 1:
    raise SystemExit(f"FEX_IOS_INTERVAL_MUTEX_PATCH_REFUSED field match count={text.count(field_old)}")

text = text.replace(include_old, include_new).replace(field_old, field_new)
path.write_text(text)

check = path.read_text()
if marker not in check or "WritePriorityMutex::Mutex IntervalsLock" not in check:
    raise SystemExit("FEX_IOS_INTERVAL_MUTEX_PATCH_VERIFY_FAILED")

print("FEX_IOS_INTERVAL_MUTEX_PATCH_OK")
