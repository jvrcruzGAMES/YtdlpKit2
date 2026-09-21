#!/usr/bin/env python3
"""Generate the release SBOM skeleton from pinned source manifests."""

import json
import pathlib

root = pathlib.Path(__file__).resolve().parent.parent
native = json.loads((root / "Scripts/native-packages.json").read_text())
runtime = json.loads((root / "Sources/YtdlpKit2/Resources/runtime-dependencies.json").read_text())
ffmpeg = json.loads((root / "Scripts/ffmpeg-kit-next.json").read_text())
components = [
    {"type": "application", "name": "YtdlpKit2", "version": "0.1.0"},
    {"type": "framework", "name": "CPython", "version": native["python"]},
    {"type": "library", "name": "PythonKit", "version": "1.0.0"},
]
for name, value in runtime["packages"].items():
    components.append({"type": "library", "name": name, "versionConstraint": value["requirement"]})
for package in native["packages"]:
    components.append({"type": "library", "name": package["name"],
                       "version": package["version"], "hashes": [
                           {"alg": "SHA-256", "content": package["sha256"]}]})
components.extend([
    {"type": "library", "name": "FFmpegKitNext", "version": ffmpeg["ffmpegKitNextVersion"],
     "licenses": [{"license": {"id": "LGPL-3.0-only"}}]},
    {"type": "library", "name": "FFmpeg", "version": ffmpeg["ffmpegVersion"],
     "licenses": [{"license": {"id": "LGPL-2.1-or-later"}}]},
])
output = {"bomFormat": "CycloneDX", "specVersion": "1.5", "version": 1,
          "components": components}
destination = root / ".native-build/ytdlpkit2-sbom.cdx.json"
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text(json.dumps(output, indent=2, sort_keys=True) + "\n")
print(destination)
