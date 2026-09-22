#!/usr/bin/env python3
"""Validate pinned native recipes and optionally build their Apple artifacts.

This driver deliberately refuses manifest entries without an explicit source
URL, SHA-256, license, and per-platform build recipe. Runtime compilation is
never performed by YtdlpKit2; release recipes added here run only in CI.
"""

import argparse
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tarfile
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
BUILD = ROOT / ".native-build"


def run(*command, cwd=None, env=None):
    print("+", " ".join(map(str, command)), flush=True)
    subprocess.run([str(item) for item in command], cwd=cwd, env=env, check=True)


def download(url, sha256, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not destination.exists():
        print(f"Downloading {url}")
        with urllib.request.urlopen(url) as response, destination.open("wb") as target:
            shutil.copyfileobj(response, target)
    actual = hashlib.sha256(destination.read_bytes()).hexdigest()
    if actual != sha256:
        destination.unlink(missing_ok=True)
        raise SystemExit(f"SHA-256 mismatch for {destination.name}: {actual}")


def extract(archive, destination):
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)
    with tarfile.open(archive) as source:
        source.extractall(destination, filter="data")


def build_brotli(package):
    # CPython headers and sysconfig data must match the exact runtime ABI.
    run(ROOT / "Scripts/download-python-runtime.py")
    support = BUILD / "cpython-support"
    support.mkdir(parents=True, exist_ok=True)
    distribution = json.loads((ROOT / "Scripts/cpython-distribution.json").read_text())
    for platform, manifest_name in (("ios", "iOS"),):
        artifact = distribution["artifacts"][manifest_name]
        archive = BUILD / "cpython-dist" / artifact["url"].rsplit("/", 1)[-1]
        extract(archive, support / platform)

    source_archive = BUILD / "downloads" / f"brotli-{package['version']}.tar.gz"
    download(package["source"], package["sha256"], source_archive)
    source_parent = BUILD / "native-src"
    extracted = source_parent / f"brotli-{package['version']}"
    extract(source_archive, source_parent)
    source = source_parent / "brotli"
    if source.exists():
        shutil.rmtree(source)
    extracted.rename(source)

    host_python = shutil.which("python3.14")
    if not host_python:
        raise SystemExit("python3.14 is required to build cp314 native packages")
    venv = BUILD / "xbuild-venv"
    if venv.exists():
        shutil.rmtree(venv)
    run(host_python, "-m", "venv", venv)
    pip = venv / "bin/pip"
    xbuild = venv / "bin/xbuild"
    run(pip, "install", "xbuild==0.2.0", "setuptools==84.0.0")
    ios = support / "ios/Python.xcframework"
    cross_env = os.environ.copy()
    tool_bins = [
        ios / "ios-arm64/bin",
        ios / "ios-arm64_x86_64-simulator/bin",
    ]
    cross_env["PATH"] = os.pathsep.join(map(str, tool_bins)) + os.pathsep + cross_env["PATH"]
    configs = [
        (ios / "ios-arm64/platform-config/arm64-iphoneos/_sysconfig_vars__ios_arm64-iphoneos.json", "ios-arm64"),
        (ios / "ios-arm64_x86_64-simulator/platform-config/arm64-iphonesimulator/_sysconfig_vars__ios_arm64-iphonesimulator.json", "ios-simulator-arm64"),
    ]
    wheels = BUILD / "native-wheels"
    for config, output in configs:
        (wheels / output).mkdir(parents=True, exist_ok=True)
        run(xbuild, "--sysconfig", config, "--outdir", wheels / output, source,
            env=cross_env)

    # xbuild 0.2 derives the platform by splitting underscores, so use a
    # temporary hyphenated filename for the x86_64 simulator configuration.
    x86_source = ios / "ios-arm64_x86_64-simulator/platform-config/x86_64-iphonesimulator/_sysconfig_vars__ios_x86_64-iphonesimulator.json"
    x86_config = x86_source.with_name("_sysconfig_vars__ios_x86-64-iphonesimulator.json")
    shutil.copy2(x86_source, x86_config)
    x86_data_source = x86_source.with_name("_sysconfigdata__ios_x86_64-iphonesimulator.py")
    shutil.copy2(x86_data_source, x86_source.with_name("_sysconfigdata__ios_x86-64-iphonesimulator.py"))
    (wheels / "ios-simulator-x86_64").mkdir(parents=True, exist_ok=True)
    run(xbuild, "--sysconfig", x86_config, "--outdir", wheels / "ios-simulator-x86_64", source,
        env=cross_env)

    env = os.environ.copy()
    env.update(MACOSX_DEPLOYMENT_TARGET="13.0", ARCHFLAGS="-arch arm64 -arch x86_64")
    run(venv / "bin/python", "setup.py", "build_ext", "--force", cwd=source, env=env)
    run(ROOT / "Scripts/package-brotli-xcframework.py")


def build_ada_url(package):
    """Cross-build ada-url's CFFI extension for every supported iOS slice."""
    run(ROOT / "Scripts/download-python-runtime.py")
    support = BUILD / "cpython-support"
    ios = support / "ios/Python.xcframework"
    if not ios.exists():
        support.mkdir(parents=True, exist_ok=True)
        distribution = json.loads((ROOT / "Scripts/cpython-distribution.json").read_text())
        artifact = distribution["artifacts"]["iOS"]
        archive = BUILD / "cpython-dist" / artifact["url"].rsplit("/", 1)[-1]
        extract(archive, support / "ios")

    source_archive = BUILD / "downloads" / f"ada_url-{package['version']}.tar.gz"
    download(package["source"], package["sha256"], source_archive)
    source_parent = BUILD / "native-src"
    extracted = source_parent / f"ada_url-{package['version']}"
    if extracted.exists():
        shutil.rmtree(extracted)
    extract(source_archive, source_parent)

    host_python = shutil.which("python3.14")
    if not host_python:
        raise SystemExit("python3.14 is required to build cp314 native packages")
    venv = BUILD / "xbuild-venv"
    if not (venv / "bin/xbuild").exists():
        run(host_python, "-m", "venv", venv)
        run(venv / "bin/pip", "install", "xbuild==0.2.0", "setuptools==84.0.0")
    xbuild = venv / "bin/xbuild"
    cross_env = os.environ.copy()
    cross_env["PATH"] = os.pathsep.join(map(str, [
        ios / "ios-arm64/bin",
        ios / "ios-arm64_x86_64-simulator/bin",
    ])) + os.pathsep + cross_env["PATH"]
    # ada.cpp is compiled with clang++, but setuptools links the CFFI module
    # through clang because the generated wrapper is C. Link libc++ explicitly.
    cross_env["LDFLAGS"] = "-lc++ " + cross_env.get("LDFLAGS", "")
    configs = [
        (ios / "ios-arm64/platform-config/arm64-iphoneos/_sysconfig_vars__ios_arm64-iphoneos.json",
         "ios-arm64"),
        (ios / "ios-arm64_x86_64-simulator/platform-config/arm64-iphonesimulator/_sysconfig_vars__ios_arm64-iphonesimulator.json",
         "ios-simulator-arm64"),
    ]
    x86_source = ios / "ios-arm64_x86_64-simulator/platform-config/x86_64-iphonesimulator/_sysconfig_vars__ios_x86_64-iphonesimulator.json"
    x86_config = x86_source.with_name("_sysconfig_vars__ios_x86-64-iphonesimulator.json")
    shutil.copy2(x86_source, x86_config)
    x86_data_source = x86_source.with_name("_sysconfigdata__ios_x86_64-iphonesimulator.py")
    shutil.copy2(x86_data_source, x86_source.with_name("_sysconfigdata__ios_x86-64-iphonesimulator.py"))
    configs.append((x86_config, "ios-simulator-x86_64"))
    wheels = BUILD / "native-wheels"
    for config, output in configs:
        destination = wheels / output
        destination.mkdir(parents=True, exist_ok=True)
        for stale in destination.glob(f"ada_url-{package['version']}-*.whl"):
            stale.unlink()
        run(xbuild, "--sysconfig", config, "--outdir", destination, extracted,
            env=cross_env)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", default="Scripts/native-packages.json")
    parser.add_argument("--output", default=".native-build/native-packages-plan.json")
    parser.add_argument("--build", action="store_true",
                        help="cross-build every supported native package")
    args = parser.parse_args()
    manifest = json.loads(pathlib.Path(args.manifest).read_text())
    required = {"name", "version", "source", "sha256", "license", "recipes"}
    platforms = {"ios-arm64", "ios-simulator-arm64", "ios-simulator-x86_64",
                 "macos-arm64", "macos-x86_64"}
    for package in manifest["packages"]:
        missing = required - package.keys()
        if missing:
            raise SystemExit(f"{package.get('name', '<unnamed>')}: missing {sorted(missing)}")
        if set(package["recipes"]) != platforms:
            raise SystemExit(f"{package['name']}: recipes must cover {sorted(platforms)}")
        if len(package["sha256"]) != 64:
            raise SystemExit(f"{package['name']}: invalid SHA-256")
    canonical = json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode()
    plan = {**manifest, "manifestSHA256": hashlib.sha256(canonical).hexdigest()}
    output = pathlib.Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(plan, indent=2, sort_keys=True) + "\n")
    print(f"Validated {len(manifest['packages'])} pinned native package recipes")
    if args.build:
        built_wheels = False
        for package in manifest["packages"]:
            if package["name"] == "Brotli":
                build_brotli(package)
            elif package["name"] == "ada-url":
                build_ada_url(package)
                built_wheels = True
            else:
                built_wheels = True
        if built_wheels:
            run(ROOT / "Scripts/package-native-wheels.py")


if __name__ == "__main__":
    sys.exit(main())
