#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
source_dir=${YTDLPKIT_PYTHON_APPLE_SUPPORT:-"$project_dir/.native-build/python-apple-support"}

if [ "${YTDLPKIT_BUILD_CPYTHON_FROM_SOURCE:-0}" != "1" ]; then
    distribution_dir="$project_dir/.native-build/cpython-dist-ios-macos"
    "$script_dir/download-python-runtime.py" --output "$distribution_dir"
    "$script_dir/package-python-runtime.sh" "$distribution_dir"
    exit 0
fi

if [ ! -d "$source_dir/.git" ]; then
    mkdir -p "$(dirname "$source_dir")"
git clone --depth 1 --branch 3.14 \
        https://github.com/beeware/Python-Apple-support.git "$source_dir"
fi

# Upstream performs true SDK cross-compilation and emits signed-app-compatible
# XCFramework slices. It intentionally does not use a host Python as runtime.
make -C "$source_dir" macOS iOS

echo "CPython support archives are in $source_dir/dist"
echo "Run Scripts/package-python-runtime.sh $source_dir/dist"
