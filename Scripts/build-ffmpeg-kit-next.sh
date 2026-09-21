#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root="$script_dir/.."
source_dir="$root/.native-build/ffmpeg-kit-next"
commit=a724ed99583dcfe2af497c794fdd6b24ddd54a4e
if ! command -v nix >/dev/null 2>&1; then
    echo "Nix is required by FFmpegKitNext's supported Apple build workflow." >&2
    echo "Install Nix, then rerun this script; SwiftPM consumers never need Nix." >&2
    exit 1
fi
if [ ! -d "$source_dir/.git" ]; then
    git clone https://github.com/arthenica/ffmpeg-kit-next.git "$source_dir"
fi
git -C "$source_dir" fetch --depth 1 origin "$commit"
git -C "$source_dir" checkout --detach "$commit"
test "$(git -C "$source_dir" rev-parse HEAD)" = "$commit"
(cd "$source_dir" && ./nix-ios.sh -p xcode26 -x --spm --target=16.0 \
    --arch=arm64,arm64-simulator,x86-64 \
    --enable-lib-ios-audiotoolbox --enable-lib-ios-avfoundation \
    --enable-lib-ios-videotoolbox --enable-lib-ios-bzip2 --enable-lib-ios-zlib)
(cd "$source_dir" && ./nix-macos.sh -p xcode26 -x --spm --target=13.0 \
    --arch=arm64,x86-64 \
    --enable-lib-macos-audiotoolbox --enable-lib-macos-avfoundation \
    --enable-lib-macos-videotoolbox --enable-lib-macos-bzip2 --enable-lib-macos-zlib)
(cd "$source_dir" && ./nix-apple.sh -p xcode26 --spm \
    --ios-target=16.0 --macos-target=13.0 \
    --disable-arch-mac-catalyst --disable-arch-appletvos \
    --disable-arch-appletvsimulator --disable-arch-xros \
    --disable-arch-xrsimulator)
"$script_dir/package-ffmpeg-kit-next.sh" "$source_dir/prebuilt"
