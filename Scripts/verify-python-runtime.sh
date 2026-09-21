#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
framework="$script_dir/../Native/CPython/Python.xcframework"
plist="$framework/Info.plist"
python_home="$script_dir/../Sources/YtdlpKit2/Resources/Runtime/python/lib/python3.14"

if [ ! -f "$plist" ]; then
    echo "Missing $plist" >&2
    exit 1
fi

if [ ! -d "$python_home" ]; then
    echo "Missing bundled Python standard library at $python_home" >&2
    exit 1
fi

plutil -lint "$plist"
python3 - "$plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], 'rb') as stream:
    manifest = plistlib.load(stream)
platforms = {item['SupportedPlatform'] for item in manifest['AvailableLibraries']}
missing = {'macos', 'ios'} - platforms
if missing:
    raise SystemExit(f"Missing platform slices: {', '.join(sorted(missing))}")
PY
echo "Verified Python.xcframework platform slices"
