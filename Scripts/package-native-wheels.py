#!/usr/bin/env python3
"""Turn pinned macOS/iOS wheels into signed-app-compatible XCFrameworks."""

import hashlib
import json
import pathlib
import plistlib
import shutil
import struct
import subprocess
import urllib.request
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
BUILD = ROOT / ".native-build/wheel-frameworks"
DOWNLOADS = ROOT / ".native-build/native-wheel-downloads"
EXTRACTED = BUILD / "extracted"
STAGE = BUILD / "stage"
OUTPUT = ROOT / "Native/PythonExtensions"
PYTHON = ROOT / "Sources/YtdlpKit2/Resources/Python"


def run(*args):
    print("+", " ".join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), check=True)


def wheel_file(package, platform, artifact):
    url, expected = artifact
    if url.startswith("built://"):
        candidates = sorted((ROOT / ".native-build/native-wheels" / platform).glob(
            f"{package['name'].replace('-', '_')}-{package['version']}-*.whl"
        ))
        if len(candidates) != 1:
            raise SystemExit(
                f"Expected one source-built {package['name']} wheel for {platform}, "
                f"found {len(candidates)}"
            )
        return candidates[0]
    destination = DOWNLOADS / package["name"] / platform / url.rsplit("/", 1)[-1]
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not destination.exists():
        print(f"Downloading {package['name']} {platform}")
        with urllib.request.urlopen(url) as source, destination.open("wb") as target:
            shutil.copyfileobj(source, target)
    actual = hashlib.sha256(destination.read_bytes()).hexdigest()
    if actual != expected:
        destination.unlink(missing_ok=True)
        raise SystemExit(f"SHA-256 mismatch for {destination.name}: {actual}")
    return destination


def module_name(path):
    parts = path.split("/")
    leaf = parts[-1].split(".", 1)[0]
    return ".".join([*parts[:-1], leaf])


def binary_members(wheel):
    with zipfile.ZipFile(wheel) as archive:
        return {module_name(name): name for name in archive.namelist() if name.endswith(".so")}


def extract_member(wheel, member, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(wheel) as archive:
        destination.write_bytes(archive.read(member))


def copy_python(package, wheel):
    with zipfile.ZipFile(wheel) as archive:
        for info in archive.infolist():
            name = info.filename
            if (info.is_dir() or name.endswith((".so", ".dylib", ".pyc"))
                    or ".dist-info/" in name or ".data/" in name
                    or name.startswith(("bin/", "Scripts/", "docs/"))):
                continue
            destination = PYTHON / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(archive.read(info))


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


def framework(module, binary, marker, platform):
    directory = STAGE / module / platform / f"{module}.framework"
    directory.mkdir(parents=True, exist_ok=True)
    installed_binary = directory / module
    shutil.copy2(binary, installed_binary)
    install_name = f"@rpath/{module}.framework/{module}"
    if platform.startswith("ios"):
        normalize_framework_binary(installed_binary, install_name)
        try:
            run("install_name_tool", "-id", install_name, installed_binary)
        except Exception:
            pass
    plist = {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleExecutable": module,
        "CFBundleIdentifier": f"dev.ytdlpkit2.python.{module}".replace("_", "-"),
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": module,
        "CFBundlePackageType": "FMWK",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1",
    }
    if platform.startswith("ios"):
        plist["MinimumOSVersion"] = "13.0"
        plist["CFBundleSupportedPlatforms"] = ["iPhoneOS"] if platform == "ios-arm64" else ["iPhoneSimulator"]
    else:
        plist["LSMinimumSystemVersion"] = "13.0"
        plist["CFBundleSupportedPlatforms"] = ["MacOSX"]
    with (directory / "Info.plist").open("wb") as output:
        plistlib.dump(plist, output)
    (directory / f"{module}.origin").write_text(marker + "\n")
    return directory


def process_package(package, wheels):
    preferred = wheels.get("macos-universal2") or wheels.get("macos-arm64")
    copy_python(package, preferred)
    members = {platform: binary_members(wheel) for platform, wheel in wheels.items()}
    # Architecture-specific acceleration modules are optional (for example,
    # PyCryptodome's AES-NI module exists only in its x86_64 iOS wheel). Only
    # package the portable module set present on every supported slice.
    expected = set.intersection(*(set(found) for found in members.values()))
    if not expected:
        raise SystemExit(f"{package['name']} has no common extension modules")

    for module in sorted(expected):
        binaries = {}
        markers = {}
        for platform, wheel in wheels.items():
            member = members[platform][module]
            binary = EXTRACTED / package["name"] / platform / module
            extract_member(wheel, member, binary)
            binaries[platform] = binary
            markers[platform] = member[:-3] + ".fwork"

        mac_platform = "macos-universal2" if "macos-universal2" in binaries else "macos-arm64"
        macos = binaries.get("macos-universal2")
        if macos is None:
            macos = BUILD / "fat" / module / "macos"
            macos.parent.mkdir(parents=True, exist_ok=True)
            run("lipo", "-create", binaries["macos-arm64"], binaries["macos-x86_64"],
                "-output", macos)
        marker = PYTHON / markers[mac_platform]
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text(f"Frameworks/{module}.framework/{module}\n")

        simulator = BUILD / "fat" / module / "ios-simulator"
        simulator.parent.mkdir(parents=True, exist_ok=True)
        run("lipo", "-create", binaries["ios-simulator-arm64"],
            binaries["ios-simulator-x86_64"], "-output", simulator)
        slices = [
            framework(module, binaries["ios-arm64"], markers["ios-arm64"], "ios-arm64"),
            framework(module, simulator, markers["ios-simulator-arm64"], "ios-simulator"),
            framework(module, macos, markers[mac_platform], "macos"),
        ]
        output = OUTPUT / f"{module}.xcframework"
        if output.exists():
            shutil.rmtree(output)
        output.parent.mkdir(parents=True, exist_ok=True)
        command = ["xcodebuild", "-create-xcframework"]
        for item in slices:
            command += ["-framework", str(item)]
        run(*command, "-output", output)


def patch_pycryptodomex_loader():
    path = PYTHON / "Cryptodome/Util/_raw_api.py"
    source = path.read_text()
    source = source.replace(
        "extension_suffixes = machinery.EXTENSION_SUFFIXES\n",
        'extension_suffixes = machinery.EXTENSION_SUFFIXES + [".abi3.fwork", ".fwork"]\n\n\n'
        'def _resolve_apple_framework(name):\n'
        '    if name.endswith(".fwork"):\n'
        '        from native_frameworks import framework_binary\n'
        '        return str(framework_binary(os.path.abspath(name)))\n'
        '    return name\n',
    )
    source = source.replace(
        '        if hasattr(ffi, "RTLD_DEEPBIND")',
        '        name = _resolve_apple_framework(name)\n'
        '        if hasattr(ffi, "RTLD_DEEPBIND")',
    )
    source = source.replace(
        '    def load_lib(name, cdecl):\n        if not cached_architecture:',
        '    def load_lib(name, cdecl):\n'
        '        name = _resolve_apple_framework(name)\n'
        '        if not cached_architecture:',
    )
    path.write_text(source)


def main():
    manifest = json.loads((ROOT / "Scripts/native-wheel-artifacts.json").read_text())
    if BUILD.exists():
        shutil.rmtree(BUILD)
    if OUTPUT.exists():
        shutil.rmtree(OUTPUT)
    for stale in (PYTHON / "cffi", PYTHON / "cryptography", PYTHON / "curl_cffi",
                  PYTHON / "Cryptodome", PYTHON / "ada_url", PYTHON / "docs"):
        if stale.exists():
            shutil.rmtree(stale)
    for stale in PYTHON.glob("_cffi_backend*"):
        stale.unlink()
    for stale in PYTHON.rglob("*.so"):
        stale.unlink()
    for stale in PYTHON.rglob("*.dylib"):
        stale.unlink()
    for package in manifest["packages"]:
        wheels = {name: wheel_file(package, name, artifact)
                  for name, artifact in package["wheels"].items()}
        process_package(package, wheels)
    patch_pycryptodomex_loader()
    # Final cleanup to guarantee zero binary executables exist inside Python resources
    for stale in PYTHON.rglob("*.so"):
        stale.unlink()
    for stale in PYTHON.rglob("*.dylib"):
        stale.unlink()
    print(f"Created {len(list(OUTPUT.glob('*.xcframework')))} extension XCFrameworks")


if __name__ == "__main__":
    main()
