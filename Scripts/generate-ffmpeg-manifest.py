#!/usr/bin/env python3
"""Generate the runtime manifest from staged FFmpegKitNext artifacts."""

import hashlib
import json
import pathlib
import plistlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
CONFIG = json.loads((ROOT / "Scripts/ffmpeg-kit-next.json").read_text())
NATIVE = ROOT / "Native/FFmpegKitNext"

artifacts = {}
for name in CONFIG["frameworks"]:
    framework = NATIVE / f"{name}.xcframework"
    with (framework / "Info.plist").open("rb") as source:
        plist = plistlib.load(source)
    slices = {}
    for item in plist["AvailableLibraries"]:
        binary = framework / item["LibraryIdentifier"] / item["BinaryPath"]
        slices[item["LibraryIdentifier"]] = hashlib.sha256(binary.read_bytes()).hexdigest()
    artifacts[name] = slices

manifest = {
    "available": True,
    **{key: CONFIG[key] for key in (
        "ffmpegKitNextVersion", "ffmpegKitNextCommit", "ffmpegVersion", "profile")},
    "ffmpegBridgeABI": 1,
    "platforms": ["ios", "macos"],
    "architectures": [
        "ios-arm64", "ios-simulator-arm64", "ios-simulator-x86_64",
        "macos-arm64", "macos-x86_64",
    ],
    "frameworks": CONFIG["frameworks"],
    "gplLibraries": CONFIG["gplLibraries"],
    "artifactSHA256": artifacts,
}
(ROOT / "Sources/YtdlpKit2/Resources/ffmpeg-native-manifest.json").write_text(
    json.dumps(manifest, indent=2, sort_keys=True) + "\n")
