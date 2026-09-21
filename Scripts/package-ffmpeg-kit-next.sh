#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root="$script_dir/.."
prebuilt=${1:-"$root/.native-build/ffmpeg-kit-next/prebuilt"}
output="$root/Native/FFmpegKitNext"
bundle=$(find "$prebuilt" -maxdepth 1 -type d -name 'umbrella-apple-xcframework-*' | sort | tail -1)
if [ -z "$bundle" ]; then
    echo "No umbrella FFmpegKitNext XCFramework bundle found under $prebuilt" >&2
    exit 1
fi
mkdir -p "$output"
for name in ffmpegkit libavcodec libavdevice libavfilter libavformat libavutil libswresample libswscale; do
    source=$(find "$bundle" -maxdepth 2 -type d -name "$name.xcframework" | head -1)
    test -n "$source" || { echo "Missing $name.xcframework" >&2; exit 1; }
    rm -rf "$output/$name.xcframework"
    cp -R "$source" "$output/$name.xcframework"
done
"$script_dir/verify-ffmpeg-kit-next.sh"
"$script_dir/generate-ffmpeg-manifest.py"
