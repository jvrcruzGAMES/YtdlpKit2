#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
framework="$script_dir/../Native/CPython/Python.xcframework"
plist="$framework/Info.plist"
python_home="$script_dir/../Sources/YtdlpKit2/Resources/Runtime/python/lib/python3.14"
stdlib_frameworks="$script_dir/../Native/PythonStdlibExtensions"

if [ ! -f "$plist" ]; then
    echo "Missing $plist" >&2
    exit 1
fi

if [ ! -d "$python_home" ]; then
    echo "Missing bundled Python standard library at $python_home" >&2
    exit 1
fi

if [ ! -f "$python_home/lib-dynload/math.cpython-314-apple.fwork" ] || \
   [ ! -f "$stdlib_frameworks/math.xcframework/Info.plist" ]; then
    echo "Missing framework-packaged iOS math standard-library module" >&2
    exit 1
fi

if find "$python_home" -type f \( -name '*.so' -o -name '*.dylib' -o -name '*.bundle' \
    -o -name '*.o' -o -name '*.a' \) \
    | grep -q .; then
    echo "Standalone native binaries found in Python resource bundle" >&2
    find "$python_home" -type f \( -name '*.so' -o -name '*.dylib' -o -name '*.bundle' \
        -o -name '*.o' -o -name '*.a' \) >&2
    exit 1
fi

if find "$python_home" -type l | grep -q .; then
    echo "Symbolic links found in Python resource bundle" >&2
    find "$python_home" -type l -print >&2
    exit 1
fi

for sdk in _hashlib _ssl
do
    framework_name="PythonStdlib_${sdk}"
    if ! find "$stdlib_frameworks/$sdk.xcframework" -path "*/$framework_name.framework/PrivacyInfo.xcprivacy" | grep -q .; then
        echo "Missing privacy manifest in $sdk standard-library XCFramework" >&2
        exit 1
    fi
    if ! codesign --verify --verbose "$stdlib_frameworks/$sdk.xcframework" >/dev/null 2>&1; then
        echo "Missing or invalid XCFramework signature for $sdk standard-library XCFramework" >&2
        exit 1
    fi
done

for sysconfig in \
    _sysconfigdata__ios_arm64-iphoneos.py \
    _sysconfigdata__ios_arm64-iphonesimulator.py \
    _sysconfigdata__ios_x86_64-iphonesimulator.py
do
    if [ ! -f "$python_home/$sysconfig" ]; then
        echo "Missing iOS sysconfig module: $sysconfig" >&2
        exit 1
    fi
done

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
echo "Verified framework-packaged iOS standard-library extensions"
echo "Verified iOS sysconfig modules"
