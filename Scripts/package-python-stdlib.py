#!/usr/bin/env python3
"""Package CPython's native standard-library extensions as signed frameworks."""

import os
import pathlib
import plistlib
import shutil
import struct
import subprocess
import sys


ROOT = pathlib.Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "Native/PythonStdlibExtensions"
STAGE = ROOT / ".native-build/python-stdlib-frameworks"
EXCLUDED_PREFIXES = ("_test", "xx")
EXCLUDED = {"_ctypes_test", "_xxtestfuzz"}
PRIVACY_MANIFEST_MODULES = {"_hashlib", "_ssl"}
PRIVACY_MANIFEST = {
    "NSPrivacyTracking": False,
    "NSPrivacyCollectedDataTypes": [],
    "NSPrivacyAccessedAPITypes": [],
}
SIGNING_IDENTITY_ENV = "YTDLPKIT_XCFRAMEWORK_SIGN_IDENTITY"


def run(*command):
    print("+", " ".join(map(str, command)), flush=True)
    subprocess.run([str(item) for item in command], check=True)


def module_name(binary):
    return binary.name.split(".cpython-", 1)[0]


def modules(directory):
    return {module_name(item): item for item in directory.glob("*.so")}


def write_privacy_manifest(framework_path):
    with (framework_path / "PrivacyInfo.xcprivacy").open("wb") as output:
        plistlib.dump(PRIVACY_MANIFEST, output)


def sign_xcframework(path):
    identity = os.environ.get(SIGNING_IDENTITY_ENV)
    if not identity:
        raise SystemExit(
            f"{path.name} contains BoringSSL/OpenSSL code and must be signed. "
            f"Set {SIGNING_IDENTITY_ENV} to your Apple Distribution signing identity."
        )
    run("codesign", "--timestamp", "--force", "--sign", identity, path)
    run("codesign", "--verify", "--verbose", path)


def normalize_framework_binary(path, install_name):
    """Turn loadable bundles into framework dylibs, including an LC_ID_DYLIB."""
    data = bytearray(path.read_bytes())
    offsets = [0]
    if data[:4] in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
        is_64 = data[:4] == b"\xca\xfe\xba\xbf"
        count = struct.unpack_from(">I", data, 4)[0]
        size = 32 if is_64 else 20
        offsets = [struct.unpack_from(">Q" if is_64 else ">I", data, 8 + size * i + 8)[0]
                   for i in range(count)]
    for offset in offsets:
        filetype = struct.unpack_from("<I", data, offset + 12)[0]
        if filetype == 8:  # MH_BUNDLE
            ncmds, sizeofcmds = struct.unpack_from("<II", data, offset + 16)
            encoded = install_name.encode() + b"\0"
            cmdsize = (24 + len(encoded) + 7) & ~7
            command_offset = offset + 32 + sizeofcmds
            if any(data[command_offset:command_offset + cmdsize]):
                raise SystemExit(f"No Mach-O header padding for LC_ID_DYLIB in {path}")
            struct.pack_into("<IIIIII", data, command_offset,
                             0xD, cmdsize, 24, 0, 0, 0)
            data[command_offset + 24:command_offset + 24 + len(encoded)] = encoded
            struct.pack_into("<II", data, offset + 16, ncmds + 1, sizeofcmds + cmdsize)
            struct.pack_into("<I", data, offset + 12, 6)  # MH_DYLIB
        elif filetype != 6:
            raise SystemExit(f"Unexpected Mach-O file type {filetype} in {path}")
    path.write_bytes(data)


def framework(module, executable, binary, platform):
    destination = STAGE / module / platform / f"{executable}.framework"
    destination.mkdir(parents=True, exist_ok=True)
    installed = destination / executable
    shutil.copy2(binary, installed)
    install_name = f"@rpath/{executable}.framework/{executable}"
    normalize_framework_binary(installed, install_name)
    run("install_name_tool", "-id", install_name, installed)
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
    if module in PRIVACY_MANIFEST_MODULES:
        write_privacy_manifest(destination)
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

    for config_dir in (python_home / "lib/python3.14").glob("config-*"):
        shutil.rmtree(config_dir)

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
        if module in PRIVACY_MANIFEST_MODULES:
            sign_xcframework(destination)
        marker = dynload / f"{module}.cpython-314-apple.fwork"
        marker.write_text(f"Frameworks/{executable}.framework/{executable}\n")

    # SwiftPM resources must contain data only. Any Mach-O image below the
    # resource bundle is rejected by App Store validation, even when it is a
    # valid CPython extension. The corresponding modules now live in signed
    # frameworks and are represented here by .fwork marker files.
    for binary in dynload.glob("*.so"):
        binary.unlink()
    for binary in dynload.glob("*.dylib"):
        binary.unlink()
    for pattern in ("*.o", "*.a"):
        for binary in python_home.rglob(pattern):
            binary.unlink()

    print(f"Packaged {len(selected)} CPython standard-library extension frameworks")


if __name__ == "__main__":
    main()
