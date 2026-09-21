#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root="$script_dir/.."
directory="$root/Native/FFmpegKitNext"
for name in ffmpegkit libavcodec libavdevice libavfilter libavformat libavutil libswresample libswscale; do
    plist="$directory/$name.xcframework/Info.plist"
    test -f "$plist" || { echo "Missing $plist" >&2; exit 1; }
    plutil -lint "$plist" >/dev/null
    python3 - "$plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as source:
    values = plistlib.load(source)["AvailableLibraries"]
platforms = {item["SupportedPlatform"] for item in values}
if platforms != {"ios", "macos"}:
    raise SystemExit(f"Expected only iOS and macOS slices, found {sorted(platforms)}")
ios = [item for item in values if item["SupportedPlatform"] == "ios"]
if not any(item.get("SupportedPlatformVariant") == "simulator" for item in ios):
    raise SystemExit("Missing iOS simulator slice")
PY
done
echo "Verified FFmpegKitNext iOS and macOS XCFrameworks"
