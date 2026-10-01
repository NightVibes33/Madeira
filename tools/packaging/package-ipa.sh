#!/bin/bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: $0 /path/to/SteamIOS.app output.ipa [sha256-output]" >&2
  exit 2
fi
APP=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
OUT=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
SHA_OUT=${3:-"$OUT.sha256"}

[[ -d "$APP" ]] || { echo "error: app bundle missing: $APP" >&2; exit 1; }
[[ -f "$APP/Info.plist" ]] || { echo "error: Info.plist missing" >&2; exit 1; }
EXEC=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist")
BUNDLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")
[[ -n "$EXEC" && -f "$APP/$EXEC" ]] || { echo "error: CFBundleExecutable missing from bundle" >&2; exit 1; }
[[ -n "$BUNDLE" ]] || { echo "error: CFBundleIdentifier is empty" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/Payload"
if /bin/cp -cR "$APP" "$TMP/Payload/$(basename "$APP")" 2>/dev/null; then
  echo "STEAMIOS_IPA_STAGE_APFS_CLONE_OK"
else
  ditto "$APP" "$TMP/Payload/$(basename "$APP")"
  echo "STEAMIOS_IPA_STAGE_DITTO_FALLBACK"
fi
(
  cd "$TMP"
  /usr/bin/zip -qry "$OUT" Payload
)

unzip -tq "$OUT" >/dev/null
LIST=$(unzip -Z1 "$OUT")
grep -q '^Payload/[^/]*\.app/Info.plist$' <<<"$LIST" || { echo "error: IPA missing Payload/*.app/Info.plist" >&2; exit 1; }
grep -q "^Payload/[^/]*\.app/$EXEC$" <<<"$LIST" || { echo "error: IPA missing executable $EXEC" >&2; exit 1; }

if command -v shasum >/dev/null; then
  shasum -a 256 "$OUT" | tee "$SHA_OUT"
else
  sha256sum "$OUT" | tee "$SHA_OUT"
fi

echo "IPA_OK bundle=$BUNDLE executable=$EXEC path=$OUT"
