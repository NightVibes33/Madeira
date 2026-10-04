#!/usr/bin/env python3
from __future__ import annotations

import pathlib
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: apply-fex-ios-apple-runtime.py <FEX checkout>")

root = pathlib.Path(sys.argv[1]).resolve()
core = root / "FEXCore/Source/Interface/Core/Core.cpp"
text = core.read_text()

start = """      {
        rpm_cas_snapshot Snap;
        if (rpm_cas_snapshot_take(&Snap)) {
"""
replacement = """#ifdef FEX_IOS_HOST
      {
        rpm_cas_snapshot Snap;
        if (rpm_cas_snapshot_take(&Snap)) {
"""
if "#ifdef FEX_IOS_HOST\n      {\n        rpm_cas_snapshot Snap;" not in text:
    if text.count(start) != 1:
        raise SystemExit("error: rpmalloc snapshot start anchor drifted")
    text = text.replace(start, replacement, 1)

end = """        }
      }
    }
  }

  /* iOS-Madeira 2026-05-14: per-thread callret tracking"""
end_replacement = """        }
      }
#endif
    }
  }

  /* iOS-Madeira 2026-05-14: per-thread callret tracking"""
if "      }\n#endif\n    }\n  }\n\n  /* iOS-Madeira 2026-05-14: per-thread callret tracking" not in text:
    if text.count(end) != 1:
        raise SystemExit("error: rpmalloc snapshot end anchor drifted")
    text = text.replace(end, end_replacement, 1)

reporter_start = """  {
    static uint64_t FfsLastCount = 0;
"""
reporter_start_replacement = """#ifdef FEX_IOS_HOST
  {
    static uint64_t FfsLastCount = 0;
"""
if "#ifdef FEX_IOS_HOST\n  {\n    static uint64_t FfsLastCount = 0;" not in text:
    if text.count(reporter_start) != 1:
        raise SystemExit("error: FFS reporter start anchor drifted")
    text = text.replace(reporter_start, reporter_start_replacement, 1)

reporter_end = """                        IosCbEntryLog[4], IosCbEntryLog[5], IosCbEntryLog[7]);
    }
  }

  /* iOS-Madeira: refuse to compile obviously-invalid guest RIPs."""
reporter_end_replacement = """                        IosCbEntryLog[4], IosCbEntryLog[5], IosCbEntryLog[7]);
    }
  }
#endif

  /* iOS-Madeira: refuse to compile obviously-invalid guest RIPs."""
if "IosCbEntryLog[4], IosCbEntryLog[5], IosCbEntryLog[7]);\n    }\n  }\n#endif\n\n  /* iOS-Madeira: refuse" not in text:
    if text.count(reporter_end) != 1:
        raise SystemExit("error: callback reporter end anchor drifted")
    text = text.replace(reporter_end, reporter_end_replacement, 1)

core.write_text(text)

arm64 = root / "FEXCore/Source/Utils/ArchHelpers/Arm64.cpp"
arm64_text = arm64.read_text()

windows_query = """  MEMORY_BASIC_INFORMATION mbi {};
  const char* type = "?";
  if (VirtualQuery(reinterpret_cast<LPCVOID>(GPRs[AddressReg]), &mbi, sizeof(mbi))) {
    type = mbi.Type == MEM_IMAGE ? "MEM_IMAGE" : mbi.Type == MEM_MAPPED ? "MEM_MAPPED" : "MEM_PRIVATE";
  }
  LogMan::Msg::EFmt("[caspal128] MISALIGNED-UNSUPPORTED Size={} addrReg=x{} addr={:#x} misalign={} "
                    "crosses16B={} | region base={} size={:#x} prot={:#x} type={} state={:#x}",
                    Size, AddressReg, GPRs[AddressReg], GPRs[AddressReg] & 15,
                    (GPRs[AddressReg] & 15) ? "yes" : "no", mbi.BaseAddress, mbi.RegionSize,
                    mbi.Protect, type, mbi.State);
"""
portable_query = """#ifdef _WIN32
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
                    "crosses16B={} | region=n/a (native Apple host)",
                    Size, AddressReg, GPRs[AddressReg], GPRs[AddressReg] & 15,
                    (GPRs[AddressReg] & 15) ? "yes" : "no");
#endif
"""
if "#ifdef _WIN32\n  MEMORY_BASIC_INFORMATION mbi {};" not in arm64_text:
    if arm64_text.count(windows_query) != 1:
        raise SystemExit("error: CASPAL VirtualQuery anchor drifted")
    arm64_text = arm64_text.replace(windows_query, portable_query, 1)

arm64.write_text(arm64_text)
print("FEX_APPLE_RUNTIME_PATCH_OK rpmalloc-telemetry=guarded reporters=guarded caspal-virtualquery=guarded")
