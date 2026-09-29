// FEXBridge.mm - Bridge between iOS app and FEXCore
// Handles JIT pool allocation, mmap hooks, and FEXCore initialization

#include "FEXBridge.h"
#include "JITAllocator.h"
#include "../../runtime/linux/elf/elf64_image.h"
#include "../../runtime/linux/syscalls/syscall_dispatch.h"
#include "../../runtime/linux/process/initial_stack.h"

// Xcode defines DEBUG=1 in debug builds which conflicts with FEX's LogMan::DEBUG enum
#ifdef DEBUG
#define SAVED_DEBUG DEBUG
#undef DEBUG
#endif

#include <FEXCore/Config/Config.h>
#include <FEXCore/Core/Context.h>
#include <FEXCore/Core/CoreState.h>
#include <FEXCore/Debug/InternalThreadState.h>
#include <FEXCore/Core/HostFeatures.h>
#include <FEXCore/Core/SignalDelegator.h>
#include <FEXCore/HLE/SyscallHandler.h>
#include <FEXCore/Utils/Allocator.h>
#include <FEXCore/Utils/AllocatorHooks.h>
#include <FEXCore/Utils/DualMap.h>
#include <FEXCore/Utils/LogManager.h>

#include <mach/mach.h>
#include <mach/vm_map.h>
#include <sys/mman.h>
#include <libkern/OSCacheControl.h>
#include <os/log.h>
#include <pthread.h>

#include <atomic>
#include <csetjmp>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <execinfo.h>
#include <signal.h>

// Existing Madeira regression fixture plus the SteamOS-iOS L0 fixture.
#include "hello_x86.h"
#include "steamos_ios_static_smoke.h"

// __clear_cache is a compiler-rt builtin for icache invalidation.
// On iOS ARM64 we provide it via sys_icache_invalidate.
extern "C" void __clear_cache(void *start, void *end) {
    sys_icache_invalidate(start, static_cast<size_t>(static_cast<char*>(end) - static_cast<char*>(start)));
}

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------
static fex_log_callback_t g_fex_log_callback = nullptr;

void fex_set_log_callback(fex_log_callback_t callback) {
    g_fex_log_callback = callback;
}

static void fex_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void fex_log(const char *fmt, ...) {
    char buf[1024];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);

    if (g_fex_log_callback) {
        g_fex_log_callback(buf);
    }
    os_log(OS_LOG_DEFAULT, "[FEX] %{public}s", buf);
    fprintf(stderr, "[FEX] %s\n", buf);
}

// ---------------------------------------------------------------------------
// JIT Memory Pool
// Dual-mapped: RX pages (from debugger) + RW pages (via vm_remap)
// ---------------------------------------------------------------------------
static constexpr size_t JIT_POOL_SIZE = 64 * 1024 * 1024; // 64MB
static constexpr size_t JIT_PAGE_SIZE = 0x4000; // 16KB iOS pages

static void *g_jit_rx_base = nullptr;  // Executable view
static void *g_jit_rw_base = nullptr;  // Writable view
static size_t g_jit_pool_size = 0;
static std::atomic<size_t> g_jit_pool_offset{0};  // Bump allocator
static std::mutex g_jit_pool_mutex;

static size_t align_up(size_t val, size_t align) {
    return (val + align - 1) & ~(align - 1);
}

// Sub-allocate from the JIT pool. Returns RX pointer (canonical address).
static void *jit_pool_alloc(size_t size) {
    size = align_up(size, JIT_PAGE_SIZE);
    size_t offset = g_jit_pool_offset.fetch_add(size, std::memory_order_relaxed);
    if (offset + size > g_jit_pool_size) {
        fex_log("JIT pool exhausted: requested %zu at offset %zu (pool size %zu)", size, offset, g_jit_pool_size);
        return MAP_FAILED;
    }
    void *rx_ptr = static_cast<uint8_t*>(g_jit_rx_base) + offset;
    fex_log("JIT pool alloc: %zu bytes at RX=%p (offset %zu/%zu)", size, rx_ptr, offset + size, g_jit_pool_size);
    return rx_ptr;
}

// Check if an address is in the JIT pool RX range
static bool is_in_jit_pool(void *addr) {
    if (!g_jit_rx_base) return false;
    uintptr_t a = reinterpret_cast<uintptr_t>(addr);
    uintptr_t base = reinterpret_cast<uintptr_t>(g_jit_rx_base);
    return a >= base && a < base + g_jit_pool_size;
}

// Initialize the JIT pool using Strategy 2 (debugger-allocated RX + vm_remap RW)
static bool jit_pool_init(void) {
    if (g_jit_rx_base) return true; // Already initialized

    if (!jit_check_debugged()) {
        fex_log("Cannot init JIT pool: debugger not attached");
        return false;
    }

    size_t size = JIT_POOL_SIZE;
    mach_port_t task = mach_task_self();

    // Step 1: Ask debugger to allocate RX pages
    fex_log("Requesting debugger to allocate %zu bytes of RX memory...", size);
    void *rx_ptr = jit26_prepare_region(NULL, size);
    if (!rx_ptr) {
        fex_log("FAIL: Debugger RX allocation returned NULL");
        return false;
    }
    fex_log("Debugger allocated RX at %p", rx_ptr);

    // Step 2: vm_remap to create RW view of the same pages
    vm_address_t rw_addr = 0;
    vm_prot_t cur_prot = 0, max_prot = 0;
    kern_return_t kr = vm_remap(
        task, &rw_addr, size, 0,
        VM_FLAGS_ANYWHERE, task,
        (vm_address_t)rx_ptr, FALSE,
        &cur_prot, &max_prot, VM_INHERIT_NONE
    );
    if (kr != KERN_SUCCESS) {
        fex_log("FAIL: vm_remap for RW mirror: %s (kr=%d)", mach_error_string(kr), kr);
        return false;
    }

    // Step 3: Set the remapped view to RW
    kr = vm_protect(task, rw_addr, size, FALSE, VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) {
        fex_log("FAIL: vm_protect(RW): %s (kr=%d)", mach_error_string(kr), kr);
        vm_deallocate(task, rw_addr, size);
        return false;
    }

    g_jit_rx_base = rx_ptr;
    g_jit_rw_base = reinterpret_cast<void*>(rw_addr);
    g_jit_pool_size = size;

    int64_t write_offset = reinterpret_cast<intptr_t>(g_jit_rw_base) - reinterpret_cast<intptr_t>(g_jit_rx_base);
    FEXCore::DualMap::WriteOffset = write_offset;

    /* NOTE: the setenv that publishes this offset to xtajit64.dll lives in
     * WineProcessBridge.m, right next to the SteamAppPath setenv — that is
     * the point where Wine snapshots the environment, so it forwards
     * reliably. Setting it here (jit_pool_init) is too early/wrong-timed
     * and did not reach Wine's GetEnvironmentVariableW. See
     * fex_get_jit_write_offset(). */

    fex_log("JIT pool initialized: RX=%p, RW=%p, size=%zu, WriteOffset=%lld",
            g_jit_rx_base, g_jit_rw_base, g_jit_pool_size, (long long)write_offset);

    // Quick coherence test
    uint32_t test_val = 0xCAFEBABE;
    memcpy(g_jit_rw_base, &test_val, sizeof(test_val));
    uint32_t readback = *static_cast<uint32_t*>(g_jit_rx_base);
    if (readback == test_val) {
        fex_log("Dual-map coherence OK");
    } else {
        fex_log("WARNING: Dual-map coherence failed: wrote 0x%x, read 0x%x", test_val, readback);
    }

    return true;
}

// ---------------------------------------------------------------------------
// Custom mmap/munmap hooks for FEXCore
// ---------------------------------------------------------------------------
static void *fex_mmap_hook(void *addr, size_t length, int prot, int flags, int fd, off_t offset) {
    if ((prot & PROT_EXEC) && g_jit_rx_base) {
        // Executable allocation: sub-allocate from our JIT pool (returns RX pointer)
        return jit_pool_alloc(length);
    }
    // Non-executable: use normal mmap
    return ::mmap(addr, length, prot, flags, fd, offset);
}

static int fex_munmap_hook(void *addr, size_t length) {
    if (is_in_jit_pool(addr)) {
        // Don't actually unmap JIT pool memory (bump allocator, no free)
        fex_log("JIT pool munmap (no-op): %p, %zu", addr, length);
        return 0;
    }
    return ::munmap(addr, length);
}

// ---------------------------------------------------------------------------
// longjmp-based thread exit for iOS
// The normal InterruptFaultPage SIGSEGV mechanism doesn't work when StikDebug
// is attached (debugger intercepts signals before app handlers).
// Instead, sys_exit uses longjmp to escape directly from the SyscallHandler.
// ---------------------------------------------------------------------------
static jmp_buf g_exit_jmp;
static int64_t g_exit_code = 0;
static bool g_exit_jmp_set = false;

// SteamOS-iOS L0 captures guest stdout so success requires the guest to have
// actually executed its Linux write(2) syscall with the exact discriminator.
static constexpr char kSteamOSL0Expected[] = "STEAMOS_IOS_ELF_OK\n";
static char g_guest_stdout_capture[256] = {};
static size_t g_guest_stdout_capture_size = 0;
static bool g_guest_stdout_capture_enabled = false;

struct FEXLinuxSyscallContext {
    FEXCore::Core::CpuStateFrame *Frame;
};

static int64_t fex_linux_write(void *, uint64_t fd_raw, uint64_t buf_raw, uint64_t count_raw) {
    const int fd = static_cast<int>(fd_raw);
    const char *buf = reinterpret_cast<const char *>(buf_raw);
    const size_t count = static_cast<size_t>(count_raw);

    if (fd != 1 && fd != 2) return -STEAMOS_LINUX_EBADF;

    if (fd == 1 && g_guest_stdout_capture_enabled) {
        const size_t available = sizeof(g_guest_stdout_capture) - g_guest_stdout_capture_size;
        const size_t copy_size = count < available ? count : available;
        if (copy_size) {
            memcpy(g_guest_stdout_capture + g_guest_stdout_capture_size, buf, copy_size);
            g_guest_stdout_capture_size += copy_size;
        }
    }
    fex_log("[x86 write fd=%d] %.*s", fd, (int)count, buf);
    return static_cast<int64_t>(count);
}

static void fex_linux_exit(void *opaque, int64_t status, int is_group_exit) {
    auto *ctx = static_cast<FEXLinuxSyscallContext *>(opaque);
    fex_log("[x86] %s(%lld)", is_group_exit ? "exit_group" : "exit", (long long)status);
    g_exit_code = status;

    if (g_exit_jmp_set) {
        fex_log("[x86] Escaping via longjmp (exit code %lld)", g_exit_code);
        longjmp(g_exit_jmp, 1);
    }

    fex_log("[x86] WARNING: longjmp not set, trying InterruptFaultPage fallback");
    if (ctx && ctx->Frame && ctx->Frame->Thread) {
        auto *Thread = ctx->Frame->Thread;
        ::mprotect(&Thread->InterruptFaultPage, sizeof(Thread->InterruptFaultPage), PROT_NONE);
    }
}

static void fex_linux_missing(void *, uint64_t number, const uint64_t args[6]) {
    fex_log("[linux-syscall-missing] number=%llu a0=0x%llx a1=0x%llx a2=0x%llx",
            (unsigned long long)number,
            (unsigned long long)args[0],
            (unsigned long long)args[1],
            (unsigned long long)args[2]);
}

static const steamos_linux_syscall_ops g_linux_syscall_ops = {
    fex_linux_write,
    fex_linux_exit,
    fex_linux_missing,
};

// ---------------------------------------------------------------------------
// Minimal SyscallHandler for FEXCore
// Handles basic syscalls so FEXCore can initialize and run trivial x86 code
// ---------------------------------------------------------------------------
class iOSSyscallHandler : public FEXCore::HLE::SyscallHandler {
public:
    iOSSyscallHandler() {
        OSABI = FEXCore::HLE::SyscallOSABI::OS_LINUX64;
    }

    static std::atomic<int> syscall_count;

    uint64_t HandleSyscall(FEXCore::Core::CpuStateFrame *Frame, FEXCore::HLE::SyscallArguments *Args) override {
        syscall_count.fetch_add(1);
        const uint64_t linux_args[6] = {
            Args->Argument[1], Args->Argument[2], Args->Argument[3],
            Args->Argument[4], Args->Argument[5], Args->Argument[6],
        };
        FEXLinuxSyscallContext context{Frame};
        return static_cast<uint64_t>(
            steamos_linux_dispatch_syscall(Args->Argument[0], linux_args,
                                           &g_linux_syscall_ops, &context));
    }

    FEXCore::HLE::ExecutableRangeInfo QueryGuestExecutableRange(
        FEXCore::Core::InternalThreadState *Thread, uint64_t Address) override {
        // Mark the entire 64-bit address space as executable.
        // Our x86 code lives at high addresses (>4GB) in the app's address space.
        return {.Base = 0, .Size = ~0ULL, .Writable = true};
    }

    std::optional<FEXCore::ExecutableFileSectionInfo> LookupExecutableFileSection(
        FEXCore::Core::InternalThreadState *Thread, uint64_t GuestAddr) override {
        return std::nullopt;
    }
};

std::atomic<int> iOSSyscallHandler::syscall_count{0};

// ---------------------------------------------------------------------------
// Minimal SignalDelegator for FEXCore
// ---------------------------------------------------------------------------
class iOSSignalDelegator : public FEXCore::SignalDelegator {
public:
    // No signals to handle on iOS for now
};

// ---------------------------------------------------------------------------
// SIGSEGV handler for InterruptFaultPage-based thread stop
// When the Dispatcher writes to InterruptFaultPage (PROT_NONE),
// this handler redirects execution to ThreadStopHandler.
// ---------------------------------------------------------------------------
static FEXCore::Core::InternalThreadState *g_current_thread = nullptr;

static void ios_sigsegv_handler(int sig, siginfo_t *info, void *ucontext) {
    if (!g_current_thread) return;

    auto *Thread = g_current_thread;
    void *fault_addr = info->si_addr;
    void *page_addr = &Thread->InterruptFaultPage;

    if (fault_addr == page_addr) {
        // Re-enable the page
        ::mprotect(page_addr, sizeof(Thread->InterruptFaultPage), PROT_READ | PROT_WRITE);

        // Redirect execution to ThreadStopHandler by modifying the signal context
        ucontext_t *uctx = static_cast<ucontext_t*>(ucontext);
        // On ARM64 Darwin, PC is in __ss.__pc
        uctx->uc_mcontext->__ss.__pc = Thread->CurrentFrame->Pointers.ThreadStopHandlerSpillSRA;
        return;
    }

    // Not our fault — re-raise with default handler
    fex_log("SIGSEGV at %p (not InterruptFaultPage %p)", fault_addr, page_addr);
    signal(SIGSEGV, SIG_DFL);
    raise(SIGSEGV);
}

// ---------------------------------------------------------------------------
// FEXCore State
// ---------------------------------------------------------------------------
static fextl::unique_ptr<FEXCore::Context::Context> g_ctx;
static iOSSyscallHandler g_syscall_handler;
static iOSSignalDelegator g_signal_delegator;
static std::atomic<bool> g_initialized{false};
static std::mutex g_init_mutex;

// LogManager handler for FEX's internal logging
static void FEXLogHandler(LogMan::DebugLevels Level, const char *Message) {
    fex_log("[FEXCore:%s] %s", LogMan::DebugLevelStr(Level), Message);
}

static void FEXThrowHandler(const char *Message) {
    fex_log("[FEXCore:THROW] %s", Message);
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

// Runtime RX->RW distance of the dual-mapped JIT pool, for xtajit64.dll.
extern "C" int64_t fex_get_jit_write_offset(void) {
    if (!g_jit_rx_base || !g_jit_rw_base) return 0;
    return reinterpret_cast<intptr_t>(g_jit_rw_base) - reinterpret_cast<intptr_t>(g_jit_rx_base);
}

bool fex_initialize(void) {
    if (g_initialized.load()) {
        return true;
    }

    std::lock_guard<std::mutex> lock(g_init_mutex);
    if (g_initialized.load()) {
        return true;
    }

    fex_log("=== FEXCore Initialization ===");

    // Step 1: Initialize JIT pool
    if (!jit_pool_init()) {
        fex_log("FAIL: Could not initialize JIT pool");
        return false;
    }

    // Step 2: Install mmap hooks BEFORE FEXCore does any allocations
    fex_log("Installing mmap hooks...");
    FEXCore::Allocator::mmap = fex_mmap_hook;
    FEXCore::Allocator::munmap = fex_munmap_hook;

    // Step 3: Install FEX log handlers
    LogMan::Msg::InstallHandler(FEXLogHandler);
    LogMan::Throw::InstallHandler(FEXThrowHandler);

    // Install temporary SIGABRT handler for debugging
    struct sigaction old_sa;
    {
        struct sigaction sa;
        sa.sa_handler = [](int sig) {
            void *bt[32];
            int count = backtrace(bt, 32);
            char **syms = backtrace_symbols(bt, count);
            fprintf(stderr, "[FEX] SIGABRT caught! Backtrace:\n");
            for (int i = 0; i < count; i++) {
                fprintf(stderr, "[FEX]   %s\n", syms[i]);
            }
            if (g_fex_log_callback) {
                g_fex_log_callback("SIGABRT caught during FEX init! Check stderr for backtrace.");
            }
            free(syms);
            // Re-raise to get the crash report
            signal(SIGABRT, SIG_DFL);
            raise(SIGABRT);
        };
        sigemptyset(&sa.sa_mask);
        sa.sa_flags = 0;
        sigaction(SIGABRT, &sa, &old_sa);
    }

    // Step 4: Initialize FEXCore config
    fex_log("Initializing FEXCore config...");
    try {
        fex_log("  Calling FEXCore::Config::Initialize()...");
        FEXCore::Config::Initialize();
        fex_log("  Config::Initialize() returned OK");

        // Set 64-bit mode - our x86 test code is x86-64
        FEXCore::Config::Set(FEXCore::Config::ConfigOption::CONFIG_IS64BIT_MODE, "1");
        fex_log("  Set IS64BIT_MODE = 1");
    } catch (const std::exception& e) {
        fex_log("FAIL: Config::Initialize() threw exception: %s", e.what());
        return false;
    } catch (...) {
        fex_log("FAIL: Config::Initialize() threw unknown exception");
        return false;
    }

    // Step 5: Create HostFeatures for Apple A15 (iPhone 13 Pro)
    fex_log("  Creating HostFeatures...");
    FEXCore::HostFeatures Features{};
    Features.DCacheLineSize = 64;
    Features.ICacheLineSize = 64;
    Features.SupportsCacheMaintenanceOps = true;
    Features.SupportsAES = true;
    Features.SupportsCRC = true;
    Features.SupportsAtomics = true;  // ARMv8.1 LSE
    Features.SupportsRCPC = true;     // ARMv8.3 RCPC
    Features.SupportsTSOImm9 = true;  // RCPC2
    Features.SupportsSHA = true;
    Features.SupportsPMULL_128Bit = true;
    Features.SupportsFCMA = true;
    Features.SupportsFlagM = true;
    Features.SupportsFlagM2 = true;
    Features.SupportsAVX = false;     // No SVE on A15
    Features.SupportsSVE128 = false;
    Features.SupportsSVE256 = false;
    // A15 has 6 performance + 2 efficiency cores
    Features.CPUMIDRs.resize(8, 0x611F0250); // A15 Firestorm MIDR (approximate)

    fex_log("Creating FEXCore context...");

    // Step 6: Create context
    try {
        g_ctx = FEXCore::Context::Context::CreateNewContext(Features);
    } catch (const std::exception& e) {
        fex_log("FAIL: CreateNewContext threw exception: %s", e.what());
        return false;
    } catch (...) {
        fex_log("FAIL: CreateNewContext threw unknown exception");
        return false;
    }
    if (!g_ctx) {
        fex_log("FAIL: CreateNewContext returned null");
        return false;
    }

    // Step 7: Set handlers
    g_ctx->SetSignalDelegator(&g_signal_delegator);
    g_ctx->SetSyscallHandler(&g_syscall_handler);

    // Step 8: Enable hardware TSO (Apple Silicon supports TSO mode)
    g_ctx->SetHardwareTSOSupport(true);

    // Step 9: Initialize core (creates Dispatcher)
    fex_log("Initializing FEXCore core (creates Dispatcher)...");
    try {
    if (!g_ctx->InitCore()) {
        fex_log("FAIL: InitCore returned false");
        g_ctx.reset();
        return false;
    }
    } catch (const std::exception& e) {
        fex_log("FAIL: InitCore threw exception: %s", e.what());
        return false;
    } catch (...) {
        fex_log("FAIL: InitCore threw unknown exception");
        return false;
    }

    // Restore original SIGABRT handler
    sigaction(SIGABRT, &old_sa, nullptr);

    g_initialized.store(true);
    fex_log("=== FEXCore initialized successfully ===");
    fex_log("JIT pool: %zu/%zu bytes used", g_jit_pool_offset.load(), g_jit_pool_size);
    return true;
}

void fex_shutdown(void) {
    if (!g_initialized) return;

    fex_log("Shutting down FEXCore...");
    g_ctx.reset();
    g_initialized = false;

    // Restore default mmap hooks
    FEXCore::Allocator::mmap = ::mmap;
    FEXCore::Allocator::munmap = ::munmap;

    LogMan::Msg::UnInstallHandler();
    LogMan::Throw::UnInstallHandler();

    fex_log("FEXCore shut down");
}

int64_t fex_test_execute(void) {
    // Guard against concurrent calls from SwiftUI rerenders
    static std::atomic<bool> running{false};
    static std::atomic<int64_t> cached_result{-999};
    if (running.exchange(true)) {
        fex_log("fex_test_execute already running, skipping duplicate call");
        return cached_result.load();
    }

    fex_log("=== FEX Execution Test ===");

    if (!g_initialized) {
        fex_log("FEXCore not initialized, initializing now...");
        if (!fex_initialize()) {
            running.store(false);
            return -1;
        }
    }

    // ---------------------------------------------------------------------------
    // SteamOS-iOS ELF loader: hardened validation/load plan + FEX execution.
    // ---------------------------------------------------------------------------
    const uint8_t *elf_data = steamos_ios_static_smoke_elf;
    const size_t elf_size = steamos_ios_static_smoke_elf_len;

    steamos_elf64_image elf_image{};
    const steamos_elf64_error elf_error =
        steamos_elf64_parse(elf_data, elf_size, JIT_PAGE_SIZE, &elf_image);
    if (elf_error != STEAMOS_ELF64_OK) {
        fex_log("STEAMOS_IOS_L0_FAIL ELF parse: %s",
                steamos_elf64_error_string(elf_error));
        running.store(false);
        return -1;
    }

    fex_log("ELF: entry=0x%llx, %u LOAD segments",
            (unsigned long long)elf_image.entry,
            (unsigned)elf_image.load_count);

    const uint64_t load_span = elf_image.load_max - elf_image.load_min;
    if (!load_span || load_span > SIZE_MAX) {
        fex_log("STEAMOS_IOS_L0_FAIL invalid ELF load span: 0x%llx",
                (unsigned long long)load_span);
        running.store(false);
        return -1;
    }
    const size_t total_map_size = static_cast<size_t>(load_span);
    fex_log("ELF: address range [0x%llx, 0x%llx), total %zu bytes",
            (unsigned long long)elf_image.load_min,
            (unsigned long long)elf_image.load_max,
            total_map_size);

    // Guest ELF memory is data from the host's perspective; FEX translates
    // x86-64 instructions into the separate RX/RW JIT arena.
    void *elf_base = ::mmap(nullptr, total_map_size, PROT_READ | PROT_WRITE,
                            MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (elf_base == MAP_FAILED) {
        fex_log("FAIL: Could not allocate %zu bytes for ELF: %s",
                total_map_size, strerror(errno));
        running.store(false);
        return -1;
    }

    fex_log("ELF: mapped at %p (original base 0x%llx)",
            elf_base, (unsigned long long)elf_image.load_min);

    struct MappedRegion { void *addr; size_t size; };
    MappedRegion mapped_regions[1] = {{elf_base, total_map_size}};
    const int num_mapped = 1;

    for (uint16_t i = 0; i < elf_image.load_count; ++i) {
        const steamos_elf64_segment &seg = elf_image.load[i];
        uint64_t destination_address = 0;
        const steamos_elf64_error map_error =
            steamos_elf64_runtime_address(
                &elf_image, reinterpret_cast<uint64_t>(elf_base),
                seg.virtual_address, &destination_address);
        if (map_error != STEAMOS_ELF64_OK) {
            fex_log("STEAMOS_IOS_L0_FAIL segment mapping: %s",
                    steamos_elf64_error_string(map_error));
            ::munmap(elf_base, total_map_size);
            running.store(false);
            return -1;
        }
        uint8_t *destination = reinterpret_cast<uint8_t *>(destination_address);

        fex_log("ELF: LOAD vaddr=0x%llx filesz=0x%llx memsz=0x%llx flags=%c%c%c -> actual %p",
                (unsigned long long)seg.virtual_address,
                (unsigned long long)seg.file_size,
                (unsigned long long)seg.memory_size,
                (seg.flags & STEAMOS_ELF64_PF_R) ? 'R' : '-',
                (seg.flags & STEAMOS_ELF64_PF_W) ? 'W' : '-',
                (seg.flags & STEAMOS_ELF64_PF_X) ? 'X' : '-',
                destination);

        if (seg.file_size) {
            memcpy(destination, elf_data + seg.file_offset,
                   static_cast<size_t>(seg.file_size));
        }
    }

    uint64_t code_addr = 0;
    const steamos_elf64_error entry_map_error =
        steamos_elf64_runtime_address(
            &elf_image, reinterpret_cast<uint64_t>(elf_base),
            elf_image.entry, &code_addr);
    if (entry_map_error != STEAMOS_ELF64_OK) {
        fex_log("STEAMOS_IOS_L0_FAIL entry mapping: %s",
                steamos_elf64_error_string(entry_map_error));
        ::munmap(elf_base, total_map_size);
        running.store(false);
        return -1;
    }
    fex_log("ELF loaded: entry point = 0x%llx (guest 0x%llx), %d mapping",
            (unsigned long long)code_addr,
            (unsigned long long)elf_image.entry,
            num_mapped);

    const uint8_t firstByte = *reinterpret_cast<const uint8_t *>(code_addr);
    fex_log("First byte at entry 0x%llx: 0x%02x",
            (unsigned long long)code_addr, firstByte);

    // Allocate a guest stack (separate from ELF segments)
    const uint64_t GUEST_STACK_SIZE = 0x10000; // 64KB
    void *stack_mem = ::mmap(nullptr, GUEST_STACK_SIZE, PROT_READ | PROT_WRITE,
                            MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (stack_mem == MAP_FAILED) {
        fex_log("FAIL: Could not allocate guest stack");
        for (int i = 0; i < num_mapped; ++i) {
            ::munmap(mapped_regions[i].addr, mapped_regions[i].size);
        }
        running.store(false);
        return -1;
    }
    uint64_t stack_addr = 0;
    const char *guest_argv[] = {"steamos-ios-l0"};
    steamos_linux_initial_stack_spec stack_spec{};
    stack_spec.argv = guest_argv;
    stack_spec.argc = 1;
    stack_spec.page_size = JIT_PAGE_SIZE;
    stack_spec.entry = code_addr;
    stack_spec.phent = elf_image.phent;
    stack_spec.phnum = elf_image.phnum;
    if (elf_image.phdr_virtual_address) {
        const steamos_elf64_error phdr_map_error =
            steamos_elf64_runtime_address(
                &elf_image, reinterpret_cast<uint64_t>(elf_base),
                elf_image.phdr_virtual_address, &stack_spec.phdr);
        if (phdr_map_error != STEAMOS_ELF64_OK) {
            fex_log("STEAMOS_IOS_L0_FAIL PHDR mapping: %s",
                    steamos_elf64_error_string(phdr_map_error));
            ::munmap(elf_base, total_map_size);
            ::munmap(stack_mem, GUEST_STACK_SIZE);
            running.store(false);
            return -1;
        }
    }

    const steamos_linux_stack_error stack_error =
        steamos_linux_build_initial_stack(
            stack_mem, GUEST_STACK_SIZE,
            reinterpret_cast<uint64_t>(stack_mem),
            &stack_spec, &stack_addr);
    if (stack_error != STEAMOS_LINUX_STACK_OK) {
        fex_log("STEAMOS_IOS_L0_FAIL initial stack: %s",
                steamos_linux_stack_error_string(stack_error));
        for (int i = 0; i < num_mapped; ++i) {
            ::munmap(mapped_regions[i].addr, mapped_regions[i].size);
        }
        ::munmap(stack_mem, GUEST_STACK_SIZE);
        running.store(false);
        return -1;
    }

    fex_log("Linux initial stack at 0x%llx (base=%p, size=0x%x, argc=1, AT_PHDR=0x%llx, AT_ENTRY=0x%llx)",
            (unsigned long long)stack_addr, stack_mem, GUEST_STACK_SIZE,
            (unsigned long long)stack_spec.phdr,
            (unsigned long long)code_addr);

    // Create a thread for execution
    fex_log("Creating FEX thread (RIP=0x%llx, RSP=0x%llx)...",
            (unsigned long long)code_addr, (unsigned long long)stack_addr);

    auto *Thread = g_ctx->CreateThread(code_addr, stack_addr);
    if (!Thread) {
        fex_log("FAIL: CreateThread returned null");
        for (int i = 0; i < num_mapped; i++) ::munmap(mapped_regions[i].addr, mapped_regions[i].size);
        ::munmap(stack_mem, GUEST_STACK_SIZE);
        running.store(false);
        return -1;
    }

    // Allocate call-ret shadow stack (needed for call/ret instructions).
    // On Linux this is done by LinuxEmulation/ThreadManager; on iOS we do it here.
    void *callret_alloc = MAP_FAILED;
    size_t callret_alloc_size = 0;
    {
        constexpr size_t CALLRET_STACK_SIZE = FEXCore::Core::InternalThreadState::CALLRET_STACK_SIZE; // 4MB
        constexpr size_t PAGE_SIZE = 0x4000; // 16KB iOS pages
        constexpr size_t ALLOC_SIZE = CALLRET_STACK_SIZE + 2 * PAGE_SIZE; // guard pages on both sides
        callret_alloc_size = ALLOC_SIZE;

        callret_alloc = ::mmap(nullptr, ALLOC_SIZE, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (callret_alloc == MAP_FAILED) {
            fex_log("FAIL: Could not allocate call-ret stack");
            g_ctx->DestroyThread(Thread);
            for (int i = 0; i < num_mapped; i++) ::munmap(mapped_regions[i].addr, mapped_regions[i].size);
            ::munmap(stack_mem, GUEST_STACK_SIZE);
            running.store(false);
            return -1;
        }

        // The usable area is between the two guard pages
        void *callret_base = static_cast<uint8_t*>(callret_alloc) + PAGE_SIZE;
        ::mprotect(callret_base, CALLRET_STACK_SIZE, PROT_READ | PROT_WRITE);

        Thread->CallRetStackBase = callret_base;
        // Start at 1/4 into the stack (allows underflow room, like Linux does)
        Thread->CurrentFrame->State.callret_sp =
            reinterpret_cast<uint64_t>(callret_base) + CALLRET_STACK_SIZE / 4;

        fex_log("Call-ret stack: alloc=%p, base=%p, sp=0x%llx",
                callret_alloc, callret_base,
                (unsigned long long)Thread->CurrentFrame->State.callret_sp);
    }

    // Initialize GDT segment table for 64-bit long mode.
    // The x86 frontend decoder reads CS segment to determine 64-bit mode.
    // Without this, segment_arrays[0] is nullptr → null deref → crash.
    {
        // Allocate a minimal GDT (1 entry at index 0, matching cs_idx=0)
        static FEXCore::Core::CPUState::gdt_segment gdt_entries[1] = {};
        gdt_entries[0].L = 1;    // Long mode (64-bit)
        gdt_entries[0].D = 0;    // Must be 0 when L=1
        gdt_entries[0].P = 1;    // Present
        gdt_entries[0].S = 1;    // Code/data segment
        gdt_entries[0].Type = 0b1011; // Execute/Read, accessed
        Thread->CurrentFrame->State.segment_arrays[0] = gdt_entries; // GDT
        Thread->CurrentFrame->State.cs_idx = 0; // Selector: index 0, GDT, RPL 0
        fex_log("GDT initialized: L=%d, segment_arrays[0]=%p",
                gdt_entries[0].L, Thread->CurrentFrame->State.segment_arrays[0]);
    }

    // Pre-flight diagnostics
    fex_log("=== Pre-flight diagnostics ===");
    fex_log("Thread=%p, CurrentFrame=%p", Thread, Thread->CurrentFrame);
    fex_log("Frame RIP=0x%llx, RSP=0x%llx",
            (unsigned long long)Thread->CurrentFrame->State.rip,
            (unsigned long long)Thread->CurrentFrame->State.gregs[FEXCore::X86State::REG_RSP]);
    fex_log("InterruptFaultPage at %p (value=%d)",
            &Thread->InterruptFaultPage, Thread->InterruptFaultPage);
    fex_log("SyscallHandlerObj=%p, SyscallHandlerFunc=%p",
            (void*)Thread->CurrentFrame->Pointers.SyscallHandlerObj,
            (void*)Thread->CurrentFrame->Pointers.SyscallHandlerFunc);

    // Verify JIT pool is still valid
    fex_log("JIT pool: RX=%p, RW=%p, size=%zu, used=%zu",
            g_jit_rx_base, g_jit_rw_base, g_jit_pool_size, g_jit_pool_offset.load());

    g_exit_code = 0;
    g_exit_jmp_set = true;
    g_guest_stdout_capture_size = 0;
    memset(g_guest_stdout_capture, 0, sizeof(g_guest_stdout_capture));
    g_guest_stdout_capture_enabled = true;

    iOSSyscallHandler::syscall_count.store(0);
    std::atomic<bool> execution_done{false};
    auto *WatchThread = Thread;
    std::thread watchdog([&execution_done, WatchThread]() {
        for (int i = 1; i <= 10; i++) {
            usleep(500000);
            if (execution_done.load()) return;
            auto &st = WatchThread->CurrentFrame->State;
            fex_log("WATCHDOG: %dms RIP=0x%llx RSP=0x%llx RAX=%lld RDI=%lld syscalls=%d",
                    i * 500,
                    (unsigned long long)st.rip,
                    (unsigned long long)st.gregs[FEXCore::X86State::REG_RSP],
                    (long long)st.gregs[FEXCore::X86State::REG_RAX],
                    (long long)st.gregs[FEXCore::X86State::REG_RDI],
                    iOSSyscallHandler::syscall_count.load());
        }
        fex_log("WATCHDOG: Execution timed out after 5s!");
    });
    fex_log("Executing x86-64 code through FEXCore...");

    if (setjmp(g_exit_jmp) == 0) {
        // Normal path: execute the thread
        g_ctx->ExecuteThread(Thread);
        // If we get here, ExecuteThread returned normally (shouldn't happen with longjmp)
        fex_log("ExecuteThread returned normally (unexpected)");
    } else {
        // longjmp path: sys_exit was called
        fex_log("Returned via longjmp from sys_exit (exit code %lld)", g_exit_code);
    }

    execution_done.store(true);
    // The watchdog captures Thread and execution_done. Join it before either
    // object goes out of scope; detaching here creates a use-after-scope race.
    if (watchdog.joinable()) watchdog.join();

    g_exit_jmp_set = false;
    g_guest_stdout_capture_enabled = false;

    // Read the exit code (set by SyscallHandler before longjmp)
    int64_t exit_code = g_exit_code;
    fex_log("Execution complete. Exit code = %lld (expected 0)", exit_code);

    // Also read CPU state for debugging
    int64_t rax_val = static_cast<int64_t>(Thread->CurrentFrame->State.gregs[FEXCore::X86State::REG_RAX]);
    int64_t rdi_val = static_cast<int64_t>(Thread->CurrentFrame->State.gregs[FEXCore::X86State::REG_RDI]);
    fex_log("CPU state: RAX=%lld, RDI=%lld", rax_val, rdi_val);

    g_ctx->DestroyThread(Thread);
    if (callret_alloc != MAP_FAILED && callret_alloc_size) {
        ::munmap(callret_alloc, callret_alloc_size);
    }
    for (int i = 0; i < num_mapped; i++) {
        ::munmap(mapped_regions[i].addr, mapped_regions[i].size);
    }
    ::munmap(stack_mem, GUEST_STACK_SIZE);

    const bool stdout_ok =
        g_guest_stdout_capture_size == sizeof(kSteamOSL0Expected) - 1 &&
        memcmp(g_guest_stdout_capture, kSteamOSL0Expected, sizeof(kSteamOSL0Expected) - 1) == 0;

    if (exit_code == 0 && stdout_ok) {
        fex_log("=== STEAMOS_IOS_L0_PASS output=STEAMOS_IOS_ELF_OK exit=0 ===");
        cached_result.store(0);
        running.store(false);
        return 0;
    }

    if (!stdout_ok) {
        fex_log("=== STEAMOS_IOS_L0_FAIL stdout mismatch: captured=%zu expected=%zu ===",
                g_guest_stdout_capture_size, sizeof(kSteamOSL0Expected) - 1);
    }
    fex_log("=== FEX ELF test result: exit_code=%lld, RAX=%lld, RDI=%lld ===", exit_code, rax_val, rdi_val);
    const int64_t result = exit_code == 0 ? -2 : exit_code;
    cached_result.store(result);
    running.store(false);
    return result;
}
