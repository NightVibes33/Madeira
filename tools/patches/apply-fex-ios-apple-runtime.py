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

core.write_text(text)
print("FEX_APPLE_RUNTIME_PATCH_OK rpmalloc-telemetry=guarded")
