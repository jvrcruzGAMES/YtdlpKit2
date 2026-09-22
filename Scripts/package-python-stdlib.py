#!/usr/bin/env python3
"""Package CPython's iOS standard-library extensions as signed frameworks."""

import pathlib
import plistlib
import shutil
import subprocess
import sys


ROOT = pathlib.Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "Native/PythonStdlibExtensions"
STAGE = ROOT / ".native-build/python-stdlib-frameworks"
EXCLUDED_PREFIXES = ("_test", "xx")
EXCLUDED = {"_ctypes_test", "_xxtestfuzz"}


def run(*command):
    print("+", " ".join(map(str, command)), flush=True)
    subprocess.run([str(item) for item in command], check=True)


def module_name(binary):
    return binary.name.split(".cpython-", 1)[0]


def modules(directory):
    return {module_name(item): item for item in directory.glob("*.so")}


def framework(module, executable, binary, platform):
    destination = STAGE / module / platform / f"{executable}.framework"
    destination.mkdir(parents=True, exist_ok=True)
    installed = destination / executable
    shutil.copy2(binary, installed)
    run("install_name_tool", "-id", f"@rpath/{executable}.framework/{executable}", installed)
    with (destination / "Info.plist").open("wb") as output:
        plistlib.dump({
            "CFBundleDevelopmentRegion": "en",
            "CFBundleExecutable": executable,
            "CFBundleIdentifier": f"dev.ytdlpkit2.python-stdlib.{module.replace('_', '-')}",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": executable,
            "CFBundlePackageType": "FMWK",
            "CFBundleShortVersionString": "3.14",
            "CFBundleVersion": "1",
            "MinimumOSVersion": "16.0",
        }, output)
    return destination


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: package-python-stdlib.py <extracted-support-root> <python-home>")
    extracted = pathlib.Path(sys.argv[1])
    python_home = pathlib.Path(sys.argv[2])
    candidates = list(extracted.rglob("Python.xcframework"))
    apple = next((item for item in candidates if (item / "ios-arm64").is_dir()), None)
    if apple is None:
        raise SystemExit("iOS Python.xcframework not found")

    device_dir = apple / "ios-arm64/lib-arm64/python3.14/lib-dynload"
    simulator_root = apple / "ios-arm64_x86_64-simulator"
    arm64_dir = simulator_root / "lib-arm64/python3.14/lib-dynload"
    x86_dir = simulator_root / "lib-x86_64/python3.14/lib-dynload"
    sources = [modules(item) for item in (device_dir, arm64_dir, x86_dir)]
    common = set.intersection(*(set(item) for item in sources))
    selected = sorted(name for name in common
                      if name not in EXCLUDED and not name.startswith(EXCLUDED_PREFIXES))
    if "math" not in selected:
        raise SystemExit("CPython iOS support distribution does not contain math")

    shutil.rmtree(STAGE, ignore_errors=True)
    shutil.rmtree(OUTPUT, ignore_errors=True)
    OUTPUT.mkdir(parents=True)
    dynload = python_home / "lib/python3.14/lib-dynload"
    dynload.mkdir(parents=True, exist_ok=True)

    # sysconfig selects one of these modules from the running Apple target.
    # The shared stdlib starts from macOS, so copy the iOS configurations in
    # explicitly instead of leaving only _sysconfigdata__darwin_darwin.py.
    sysconfig_names = {
        "_sysconfigdata__ios_arm64-iphoneos.py",
        "_sysconfigdata__ios_arm64-iphonesimulator.py",
        "_sysconfigdata__ios_x86_64-iphonesimulator.py",
    }
    discovered = {}
    for candidate in apple.rglob("_sysconfigdata__ios_*.py"):
        if candidate.name in sysconfig_names:
            discovered[candidate.name] = candidate
    missing = sysconfig_names - discovered.keys()
    if missing:
        raise SystemExit(f"CPython iOS sysconfig modules are missing: {sorted(missing)}")
    for name, source in discovered.items():
        shutil.copy2(source, python_home / "lib/python3.14" / name)

    for module in selected:
        executable = f"PythonStdlib_{module}"
        simulator = STAGE / module / "simulator" / executable
        simulator.parent.mkdir(parents=True, exist_ok=True)
        run("lipo", "-create", sources[1][module], sources[2][module], "-output", simulator)
        device_framework = framework(module, executable, sources[0][module], "ios-arm64")
        simulator_framework = framework(module, executable, simulator, "ios-simulator")
        destination = OUTPUT / f"{module}.xcframework"
        run("xcodebuild", "-create-xcframework",
            "-framework", device_framework,
            "-framework", simulator_framework,
            "-output", destination)
        marker = dynload / f"{module}.cpython-314-apple.fwork"
        marker.write_text(f"Frameworks/{executable}.framework/{executable}\n")

    print(f"Packaged {len(selected)} CPython standard-library extension frameworks")


if __name__ == "__main__":
    main()
