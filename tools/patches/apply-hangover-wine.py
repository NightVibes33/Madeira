#!/usr/bin/env python3
"""Apply the SteamIOS Hangover CPU-module contract to the pinned iOS Wine fork.

This deliberately patches the existing Madeira/iOS Wine source instead of
replacing it with stock Hangover Wine.  SteamIOS keeps its iOS JIT, Mach,
pseudo-process, display, audio, guest-window and loader lifecycle work while
adopting Hangover's explicit HODLL/HODLL64 translator selection and canonical
FEX module names.

The transform is fail-closed and idempotent.
"""
from __future__ import annotations

from pathlib import Path
import sys

MARKER = "STEAMIOS_HANGOVER_PORT_V1"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one source match, got {count}")
    return text.replace(old, new, 1)


def patch_loader(path: Path) -> None:
    s = path.read_text()
    if MARKER in s:
        return

    helper = r'''
/* STEAMIOS_HANGOVER_PORT_V1
 * Keep Madeira's iOS ARM64EC loader lifecycle but expose Hangover's explicit
 * x86-64 CPU-module selector. */
static DWORD steamios_loader_get_environment_variable_w( LPCWSTR name, LPWSTR val, DWORD size )
{
    UNICODE_STRING us_name, us_value;
    NTSTATUS status;
    DWORD len;

    RtlInitUnicodeString( &us_name, name );
    us_value.Length = 0;
    us_value.MaximumLength = (size ? size - 1 : 0) * sizeof(WCHAR);
    us_value.Buffer = val;
    status = RtlQueryEnvironmentVariable_U( NULL, &us_name, &us_value );
    len = us_value.Length / sizeof(WCHAR);
    if (status == STATUS_BUFFER_TOO_SMALL) return len + 1;
    if (status) return 0;
    if (!size) return len + 1;
    val[len] = 0;
    return len;
}

'''
    s = replace_once(
        s,
        "#ifdef __arm64ec__\n\nstatic void load_arm64ec_module(void)",
        "#ifdef __arm64ec__\n" + helper + "static void load_arm64ec_module(void)",
        "loader helper insertion",
    )
    s = replace_once(
        s,
        r'    WCHAR module[64] = L"C:\\windows\\system32\\xtajit64.dll";',
        r'    WCHAR module[64] = L"C:\\windows\\system32\\libarm64ecfex.dll";' + "\n"
        r'    WCHAR cpu_dll[32];',
        "ARM64EC canonical module",
    )
    s = replace_once(
        s,
        "    HANDLE key;\n\n    InitializeObjectAttributes( &attr, &nameW, OBJ_CASE_INSENSITIVE, 0, NULL );",
        """    HANDLE key;
    DWORD res;

    if ((res = steamios_loader_get_environment_variable_w( L"HODLL64", cpu_dll, ARRAY_SIZE(cpu_dll) )) &&
        res < ARRAY_SIZE(cpu_dll))
    {
        ULONG dirlen = wcslen( L"C:\\\\windows\\\\system32\\\\" );
        ULONG size = sizeof(module) - (dirlen + 1) * sizeof(WCHAR);
        memset( module + dirlen, 0, size );
        memcpy( module + dirlen, cpu_dll, min( res * sizeof(WCHAR), size ));
    }
    else
    {
        InitializeObjectAttributes( &attr, &nameW, OBJ_CASE_INSENSITIVE, 0, NULL );""",
        "ARM64EC HODLL64 branch",
    )
    s = replace_once(
        s,
        """        NtClose( key );
    }

    if ((status = load_dll( NULL, module, 0, &wm, FALSE )))""",
        """        NtClose( key );
    }
    }

    if ((status = load_dll( NULL, module, 0, &wm, FALSE )))""",
        "ARM64EC registry fallback close",
    )
    path.write_text(s)


def patch_wow64(path: Path) -> None:
    s = path.read_text()
    if MARKER in s:
        return

    marker = """/**********************************************************************
 *           get_cpu_dll_name
 */
"""
    helper = r'''/* STEAMIOS_HANGOVER_PORT_V1
 * Match Hangover's HODLL contract while retaining Madeira's iOS-specific
 * WoW64 loader, guest-window and context handling. */
static DWORD steamios_wow64_get_environment_variable_w( LPCWSTR name, LPWSTR val, DWORD size )
{
    UNICODE_STRING us_name, us_value;
    NTSTATUS status;
    DWORD len;

    RtlInitUnicodeString( &us_name, name );
    us_value.Length = 0;
    us_value.MaximumLength = (size ? size - 1 : 0) * sizeof(WCHAR);
    us_value.Buffer = val;
    status = RtlQueryEnvironmentVariable_U( NULL, &us_name, &us_value );
    len = us_value.Length / sizeof(WCHAR);
    if (status == STATUS_BUFFER_TOO_SMALL) return len + 1;
    if (status) return 0;
    if (!size) return len + 1;
    val[len] = 0;
    return len;
}


'''
    s = replace_once(s, marker, helper + marker, "WoW64 helper insertion")
    s = replace_once(
        s,
        """    static ULONG buffer[32];
    KEY_VALUE_PARTIAL_INFORMATION *info = (KEY_VALUE_PARTIAL_INFORMATION *)buffer;
    OBJECT_ATTRIBUTES attr;""",
        """    static ULONG buffer[32];
    KEY_VALUE_PARTIAL_INFORMATION *info = (KEY_VALUE_PARTIAL_INFORMATION *)buffer;
    WCHAR *cpu_dll = (WCHAR *)buffer;
    OBJECT_ATTRIBUTES attr;""",
        "WoW64 CPU buffer",
    )
    s = replace_once(
        s,
        """    HANDLE key;
    ULONG size;

    switch (current_machine)""",
        """    HANDLE key;
    ULONG size;
    UINT res;

    if ((res = steamios_wow64_get_environment_variable_w( L"HODLL", cpu_dll, ARRAY_SIZE(buffer) )) &&
        res < ARRAY_SIZE(buffer))
    {
        *platform_default = (current_machine == IMAGE_FILE_MACHINE_I386 &&
                             native_machine == IMAGE_FILE_MACHINE_ARM64)
                            ? L"libwow64fex.dll" : cpu_dll;
        return cpu_dll;
    }

    switch (current_machine)""",
        "WoW64 HODLL branch",
    )
    s = replace_once(
        s,
        '        ret = (native_machine == IMAGE_FILE_MACHINE_ARM64 ? L"xtajit.dll" : L"wow64cpu.dll");',
        '        ret = (native_machine == IMAGE_FILE_MACHINE_ARM64 ? L"libwow64fex.dll" : L"wow64cpu.dll");',
        "WoW64 canonical default",
    )
    path.write_text(s)



TLS_INDEX_SYNC_MARKER = "STEAMIOS_TLS_INDEX_POOL_SYNC_V1"

def patch_arm64ec_tls_index_sync(path: Path) -> None:
    s = path.read_text()
    if TLS_INDEX_SYNC_MARKER in s:
        return

    old = """    *(DWORD *)dir->AddressOfIndex = i;
    tls_dirs[i] = *dir;
"""
    new = """    *(DWORD *)dir->AddressOfIndex = i;
#ifdef __arm64ec__
    /* STEAMIOS_TLS_INDEX_POOL_SYNC_V1
     * ARM64EC PE images execute from the SteamIOS JIT-pool copy. Its .data
     * snapshot is created at image-map time, before alloc_tls_slot() writes
     * AddressOfIndex. Without mirroring this late loader write, compiler TLS
     * sequences in the executing pool copy keep the image's initial -1 index
     * and index TEB->ThreadLocalStoragePointer with 0xffffffff.
     *
     * Mirror only the DWORD TLS index, using the same xlate_ios_jit() path
     * already used below for ARM64EC IAT/data synchronization. */
    {
        extern void *xlate_ios_jit( void *ptr );
        void *slot = (void *)dir->AddressOfIndex;
        void *pslot = xlate_ios_jit( slot );

        if (pslot && pslot != slot)
        {
            static int tls_sync_n;
            *(volatile DWORD *)pslot = i;
            if (tls_sync_n < 16)
            {
                tls_sync_n++;
                ERR( "[tls-sync] ml1147 slot=%lu module=%s pe_index=%p pool_index=%p pe=%lu pool=%lu\\n",
                     i, debugstr_w(mod->BaseDllName.Buffer), slot, pslot,
                     *(DWORD *)slot, *(volatile DWORD *)pslot );
            }
        }
    }
#endif
    tls_dirs[i] = *dir;
"""
    s = replace_once(s, old, new, "ARM64EC TLS-index JIT-pool sync")
    path.write_text(s)


LOADER_IMAGE_NOTIFY_MARKER = "STEAMIOS_LOADER_NOTIFY_DEDUP_V1"

def patch_arm64ec_loader_notify(path: Path) -> None:
    s = path.read_text()
    if LOADER_IMAGE_NOTIFY_MARKER in s:
        return

    s = replace_once(
        s,
        """    static LONG guard;  /* MADEIRA_IMAGE_MAP_GUARD, read once: 0 not yet, 1 off, 2 on */
    BOOL entered = FALSE;
""",
        """    static LONG guard;  /* MADEIRA_IMAGE_MAP_GUARD, read once: 0 not yet, 1 off, 2 on */
""",
        "ARM64EC loader dedup unused state",
    )

    old = """    if (guard == 2) entered = enter_syscall_callback();
    pNotifyImageMap( base );
    if (entered) leave_syscall_callback();
"""
    new = """    /* STEAMIOS_LOADER_NOTIFY_DEDUP_V1
     * On iOS the successful NtMapViewOfSection path is authoritative and has
     * already registered executable sections with FEX before the loader reaches
     * this semantic callback. Re-registering the same image can park the ARM64EC
     * loader inside FEX's interval synchronization (observed on Steam's first
     * sechost.dll map). When the SteamIOS guard is enabled, suppress this
     * duplicate loader-side registration entirely. */
    if (guard == 2)
    {
        ERR( "[ldr-image] ml1145 SKIP duplicate loader registration base=%p peb=%p\\n",
             base, RtlGetCurrentPeb() );
        return;
    }

    pNotifyImageMap( base );
"""
    s = replace_once(s, old, new, "ARM64EC loader image-map dedup")
    path.write_text(s)


GAMEPAD_MARKER = "STEAMIOS_GAMEPAD_TELEMETRY_V1"


def patch_gamepad_bridge(ntuser: Path, xinput: Path) -> None:
    s = ntuser.read_text()
    if GAMEPAD_MARKER not in s:
        old = '''enum
{
    NtUserGamepadOp_State,   /* buffer: XINPUT_STATE        (16 bytes, out) */
    NtUserGamepadOp_Caps,    /* buffer: XINPUT_CAPABILITIES (20 bytes, out) */
};'''
        new = '''enum
{
    NtUserGamepadOp_State,     /* buffer: XINPUT_STATE               (16 bytes, out) */
    NtUserGamepadOp_Caps,      /* buffer: XINPUT_CAPABILITIES        (20 bytes, out) */
    NtUserGamepadOp_Vibration, /* buffer: XINPUT_VIBRATION            (4 bytes, in)  */
    NtUserGamepadOp_Battery,   /* buffer: XINPUT_BATTERY_INFORMATION  (2 bytes, out) */
};
/* STEAMIOS_GAMEPAD_TELEMETRY_V1 */'''
        s = replace_once(s, old, new, "GameController host op ABI")
        ntuser.write_text(s)

    s = xinput.read_text()
    if GAMEPAD_MARKER not in s:
        old = '''    if (!vibration) return ERROR_BAD_ARGUMENTS;
    /* Host capabilities do not advertise force feedback. */
    if (host_pad_state(index, &host_state)) return ERROR_SUCCESS;

    start_update_thread();'''
        new = '''    if (!vibration) return ERROR_BAD_ARGUMENTS;
    if (host_pad_state(index, &host_state))
    {
        NtUserGetGamepadState(index, NtUserGamepadOp_Vibration, vibration);
        return ERROR_SUCCESS;
    }

    start_update_thread();'''
        s = replace_once(s, old, new, "XInput host vibration")

        old = '''    /* Battery reporting is not part of the host snapshot. Do not invent a
     * wired/full battery for a wireless controller. */
    if (host_pad_state(index, &host_state))
    {
        if (!battery) return ERROR_BAD_ARGUMENTS;
        battery->BatteryType = BATTERY_TYPE_UNKNOWN;
        battery->BatteryLevel = BATTERY_LEVEL_EMPTY;
        return ERROR_SUCCESS;
    }'''
        new = '''    if (host_pad_state(index, &host_state))
    {
        if (!battery) return ERROR_BAD_ARGUMENTS;
        if (!NtUserGetGamepadState(index, NtUserGamepadOp_Battery, battery))
        {
            battery->BatteryType = BATTERY_TYPE_UNKNOWN;
            battery->BatteryLevel = BATTERY_LEVEL_EMPTY;
        }
        return ERROR_SUCCESS;
    }

    /* STEAMIOS_GAMEPAD_TELEMETRY_V1 */'''
        s = replace_once(s, old, new, "XInput host battery")
        xinput.write_text(s)


def patch_windows11(version_c: Path, wine_inf: Path) -> None:
    s = version_c.read_text()
    if "10, 0, 26100" not in s:
        s = replace_once(
            s,
            "sizeof(RTL_OSVERSIONINFOEXW), 10, 0, 22000, VER_PLATFORM_WIN32_NT,",
            "sizeof(RTL_OSVERSIONINFOEXW), 10, 0, 26100, VER_PLATFORM_WIN32_NT,",
            "Windows 11 build",
        )
    if "VersionData[WIN11]; /* STEAMIOS_HANGOVER_PORT_V1 */" not in s:
        s = replace_once(
            s,
            "current_version = &VersionData[WIN10];",
            "current_version = &VersionData[WIN11]; /* STEAMIOS_HANGOVER_PORT_V1 */",
            "Windows default profile",
        )
    version_c.write_text(s)

    s = wine_inf.read_text()
    replacements = {
        'HKLM,%CurrentVersionNT%,"CurrentBuild",2,"19045"':
            'HKLM,%CurrentVersionNT%,"CurrentBuild",2,"26100"',
        'HKLM,%CurrentVersionNT%,"CurrentBuildNumber",2,"19045"':
            'HKLM,%CurrentVersionNT%,"CurrentBuildNumber",2,"26100"',
        'HKLM,%CurrentVersionNT%,"UBR",0x10003,5796':
            'HKLM,%CurrentVersionNT%,"UBR",0x10003,0',
        'HKLM,%CurrentVersionNT%,"ProductName",2,"Windows 10 Pro"':
            'HKLM,%CurrentVersionNT%,"ProductName",2,"Windows 11 Pro"',
    }
    for old, new in replacements.items():
        if new not in s:
            s = replace_once(s, old, new, f"wine.inf {old}")
    if MARKER not in s:
        s += "\n; " + MARKER + " Windows user-mode profile: Windows 11 build 26100\n"
    wine_inf.write_text(s)


def main() -> int:
    wine = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("wine")
    loader = wine / "dlls/ntdll/loader.c"
    wow64 = wine / "dlls/wow64/syscall.c"
    version_c = wine / "dlls/ntdll/version.c"
    wine_inf = wine / "loader/wine.inf.in"
    ntuser = wine / "include/ntuser.h"
    xinput = wine / "dlls/xinput1_3/main.c"
    signal_arm64ec = wine / "dlls/ntdll/signal_arm64ec.c"

    for p in (loader, wow64, version_c, wine_inf, ntuser, xinput, signal_arm64ec):
        if not p.is_file():
            raise SystemExit(f"missing Wine source: {p}")

    patch_loader(loader)
    patch_arm64ec_tls_index_sync(loader)
    patch_wow64(wow64)
    patch_windows11(version_c, wine_inf)
    patch_gamepad_bridge(ntuser, xinput)
    patch_arm64ec_loader_notify(signal_arm64ec)

    checks = {
        loader: ["HODLL64", "libarm64ecfex.dll", MARKER, TLS_INDEX_SYNC_MARKER,
                 "[tls-sync] ml1147", "arm64ec_process_init_dispatchers",
                 "process_attach( wm->ldr.DdagNode"],
        wow64: ["HODLL", "libwow64fex.dll", MARKER,
                "MemoryWineIosJitPoolAddress"],
        version_c: ["VersionData[WIN11]", "10, 0, 26100", MARKER],
        wine_inf: ['"Windows 11 Pro"', '"26100"', MARKER],
        ntuser: ["NtUserGamepadOp_Vibration", "NtUserGamepadOp_Battery", GAMEPAD_MARKER],
        xinput: ["NtUserGamepadOp_Vibration", "NtUserGamepadOp_Battery", GAMEPAD_MARKER],
        signal_arm64ec: [LOADER_IMAGE_NOTIFY_MARKER, "ml1145 SKIP duplicate loader registration",
                         "MADEIRA_IMAGE_MAP_GUARD"],
    }
    for p, needles in checks.items():
        content = p.read_text()
        for needle in needles:
            if needle not in content:
                raise SystemExit(f"post-patch verification failed: {p}: {needle}")

    print("STEAMOS_HANGOVER_WINE_PATCH_OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())