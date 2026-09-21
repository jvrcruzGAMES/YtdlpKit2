#!/usr/bin/env python3
"""Download and verify the pinned CPython Apple support distribution."""

import argparse
import hashlib
import json
import pathlib
import urllib.request


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", default="Scripts/cpython-distribution.json")
    parser.add_argument("--output", default=".native-build/cpython-dist")
    args = parser.parse_args()
    manifest = json.loads(pathlib.Path(args.manifest).read_text())
    output = pathlib.Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    for platform, artifact in manifest["artifacts"].items():
        destination = output / artifact["url"].rsplit("/", 1)[-1]
        if not destination.exists():
            print(f"Downloading CPython support for {platform}")
            with urllib.request.urlopen(artifact["url"]) as response, destination.open("wb") as target:
                while chunk := response.read(1024 * 1024):
                    target.write(chunk)
        actual = hashlib.sha256(destination.read_bytes()).hexdigest()
        if actual != artifact["sha256"]:
            destination.unlink(missing_ok=True)
            raise SystemExit(f"SHA-256 mismatch for {platform}: {actual}")
        print(f"Verified {platform}: {destination}")


if __name__ == "__main__":
    main()
