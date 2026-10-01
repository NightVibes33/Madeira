#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit("usage: apply-fex-interval-mutex.py <InvalidationTracker.h> <InvalidationTracker.cpp>")

header_path = Path(sys.argv[1])
cpp_path = Path(sys.argv[2])
header = header_path.read_text()
cpp = cpp_path.read_text()

HEADER_MARKER = "iOS-Madeira ml1144: re-entrant-safe interval RW lock"
CPP_MARKER = "iOS-Madeira ml1145: token-scoped recursive interval writer"

include_old = "#include <FEXCore/Utils/IntervalList.h>\n#include <FEXCore/HLE/SyscallHandler.h>\n"
include_new = "#include <FEXCore/Utils/IntervalList.h>\n#include <FEXCore/HLE/SyscallHandler.h>\n#include <FEXCore/Utils/WritePriorityMutex.h>\n"

field_old = "  std::shared_mutex IntervalsLock;\n"
field_new = """#ifdef FEX_IOS_HOST
  /* iOS-Madeira ml1144: re-entrant-safe interval RW lock.
   *
   * The Steam startup freeze was symbolicated to InvalidationTracker + 0x38.
   * With LLVM 23.1.2 libc++/Win64, the two IntervalList vectors occupy 0x30
   * bytes, std::shared_mutex starts at +0x30, and +0x08 is __gate1_: the
   * condition variable used by readers and later writers after the writer bit
   * is set.
   *
   * FEX's Windows/iOS invalidation paths can be synchronously re-entered by
   * exception/memory-notification machinery while the interrupted frame owns
   * this lock exclusively. WritePriorityMutex already supports the required
   * iOS writer->shared self-grant and reports owners/holders on a stuck wait.
   * Exclusive recursion is paired separately by ScopedIntervalWriteLock in
   * InvalidationTracker.cpp.
   *
   * Keep stock std::shared_mutex everywhere else. */
  FEXCore::Utils::WritePriorityMutex::Mutex IntervalsLock;
#else
  std::shared_mutex IntervalsLock;
#endif
"""

if HEADER_MARKER not in header:
    if header.count(include_old) != 1:
        raise SystemExit(f"FEX_IOS_INTERVAL_MUTEX_PATCH_REFUSED include match count={header.count(include_old)}")
    if header.count(field_old) != 1:
        raise SystemExit(f"FEX_IOS_INTERVAL_MUTEX_PATCH_REFUSED field match count={header.count(field_old)}")
    header = header.replace(include_old, include_new).replace(field_old, field_new)
    header_path.write_text(header)

guard_anchor = "namespace FEX::Windows {\n"
guard_new = """namespace FEX::Windows {

/* iOS-Madeira ml1145: token-scoped recursive interval writer.
 *
 * WritePriorityMutex intentionally does not make lock() recursively writable:
 * doing that globally previously leaked nesting through try_lock()/lock()
 * call-site mixtures.  InvalidationTracker's exclusive scopes are all lexical
 * RAII scopes, so use the mutex's token API here.  A nested exclusive entry on
 * the owning thread receives a non-owning token; only the outer token unlocks.
 * This closes write->write callback recursion while the mutex itself closes
 * write->shared recursion. */
template<typename MutexT>
class ScopedIntervalWriteLock final {
public:
  explicit ScopedIntervalWriteLock(MutexT& Mutex)
    : Mutex {Mutex}
#ifdef FEX_IOS_HOST
    , Owns {Mutex.ios_lock_write_nested_aware()}
#else
    , Owns {true}
#endif
  {
#ifndef FEX_IOS_HOST
    Mutex.lock();
#endif
  }

  ~ScopedIntervalWriteLock() {
    if (Owns) {
      Mutex.unlock();
    }
  }

  ScopedIntervalWriteLock(const ScopedIntervalWriteLock&) = delete;
  ScopedIntervalWriteLock& operator=(const ScopedIntervalWriteLock&) = delete;

private:
  MutexT& Mutex;
  bool Owns;
};
"""

unique_old = "    std::unique_lock Lock(IntervalsLock);"
unique_new = "    ScopedIntervalWriteLock Lock(IntervalsLock);"
unique_old2 = "  std::unique_lock Lock(IntervalsLock);"
unique_new2 = "  ScopedIntervalWriteLock Lock(IntervalsLock);"

if CPP_MARKER not in cpp:
    if cpp.count(guard_anchor) != 1:
        raise SystemExit(f"FEX_IOS_INTERVAL_MUTEX_PATCH_REFUSED namespace anchor count={cpp.count(guard_anchor)}")
    count4 = cpp.count(unique_old)
    count2 = cpp.count(unique_old2)
    # count2 includes the four-space matches as substrings, so do replacements
    # from the more-indented spelling first and verify the final source.
    if count4 < 1:
        raise SystemExit("FEX_IOS_INTERVAL_MUTEX_PATCH_REFUSED no nested unique-lock sites")
    cpp = cpp.replace(guard_anchor, guard_new, 1)
    cpp = cpp.replace(unique_old, unique_new)
    cpp = cpp.replace(unique_old2, unique_new2)
    if "std::unique_lock Lock(IntervalsLock);" in cpp:
        raise SystemExit("FEX_IOS_INTERVAL_MUTEX_PATCH_REFUSED unique lock site remained")
    cpp_path.write_text(cpp)

header_check = header_path.read_text()
cpp_check = cpp_path.read_text()
if HEADER_MARKER not in header_check or "WritePriorityMutex::Mutex IntervalsLock" not in header_check:
    raise SystemExit("FEX_IOS_INTERVAL_MUTEX_HEADER_VERIFY_FAILED")
if CPP_MARKER not in cpp_check or "ScopedIntervalWriteLock Lock(IntervalsLock);" not in cpp_check:
    raise SystemExit("FEX_IOS_INTERVAL_MUTEX_CPP_VERIFY_FAILED")
if "std::unique_lock Lock(IntervalsLock);" in cpp_check:
    raise SystemExit("FEX_IOS_INTERVAL_MUTEX_CPP_VERIFY_FAILED unique lock remained")

print("FEX_IOS_INTERVAL_MUTEX_PATCH_OK")
