// wine_stubs.c - Provide missing symbols for Wine on iOS

#include <CoreFoundation/CoreFoundation.h>
#include <libkern/OSCacheControl.h>
#include <stddef.h>

// Wine build version string (normally generated at compile time)
const char wine_build[] = "wine-10.0-ios";

// IOPowerSources stubs - not available on iOS
CFTypeRef IOPSCopyPowerSourcesInfo(void) { return NULL; }
CFArrayRef IOPSCopyPowerSourcesList(CFTypeRef blob) { (void)blob; return NULL; }
CFDictionaryRef IOPSGetPowerSourceDescription(CFTypeRef blob, CFTypeRef ps) {
    (void)blob; (void)ps; return NULL;
}

// Wine's NtFlushInstructionCache path expects the compiler-runtime
// __clear_cache(begin, end) entry point. compiler-rt does not export that
// symbol to this iOS app link, so provide the Darwin implementation here.
// This is required for generated/JIT code to become visible to the CPU.
void __clear_cache(char *begin, char *end)
{
    if (!begin || !end || end <= begin) return;
    size_t length = (size_t)(end - begin);
    sys_dcache_flush(begin, length);
    sys_icache_invalidate(begin, length);
}
