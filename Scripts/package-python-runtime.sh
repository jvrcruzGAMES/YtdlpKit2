#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <python-apple-support-dist-directory-or-archive>" >&2
    exit 64
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
input=$1
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT HUP INT TERM

if [ -d "$input" ]; then
    find "$input" -name '*.tar.gz' -maxdepth 1 -exec tar -xzf {} -C "$stage" \;
else
    tar -xzf "$input" -C "$stage"
fi

frameworks=$(find "$stage" -type d -name Python.xcframework -print)
if [ -z "$frameworks" ]; then
    echo "No Python.xcframework found in support package(s)" >&2
    exit 1
fi

destination="$project_dir/Native/CPython/Python.xcframework"
mkdir -p "$(dirname "$destination")"
rm -rf "$destination"
set --
for framework in $frameworks; do
    for slice in "$framework"/*/Python.framework; do
        [ -d "$slice" ] || continue
        set -- "$@" -framework "$slice"
    done
done
xcodebuild -create-xcframework "$@" -output "$destination"

stdlib=$(find "$stage" -type d -path '*/lib/python3.14' -print -quit)
if [ -z "$stdlib" ]; then
    echo "No Python 3.14 standard library found in support package(s)" >&2
    exit 1
fi
python_home="$project_dir/Sources/YtdlpKit2/Resources/Runtime/python"
rm -rf "$python_home"
mkdir -p "$python_home/lib"
ditto "$stdlib" "$python_home/lib/python3.14"
"$script_dir/verify-python-runtime.sh"
