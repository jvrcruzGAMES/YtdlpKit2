#!/usr/bin/env python3
"""Package verified Brotli wheels as one signed-app-compatible XCFramework."""

import pathlib
import shutil
import subprocess
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
WHEELS = ROOT / ".native-build/native-wheels"
STAGE = ROOT / ".native-build/brotli-framework"
OUTPUT = ROOT / "Native/Brotli/_brotli.xcframework"


def extension(wheel_dir, output):
    wheel = next(wheel_dir.glob("brotli-1.2.0-*.whl"))
    with zipfile.ZipFile(wheel) as archive:
        member = next(name for name in archive.namelist() if name.startswith("_brotli") and name.endswith(".so"))
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(archive.read(member))
        if not (ROOT / "Sources/YtdlpKit2/Resources/Python/brotli.py").exists():
            (ROOT / "Sources/YtdlpKit2/Resources/Python/brotli.py").write_bytes(archive.read("brotli.py"))


def one_directory(pattern):
    matches = list((ROOT / ".native-build/native-src/brotli/bin").glob(pattern))
    if len(matches) != 1:
        raise SystemExit(f"Expected one build directory matching {pattern}, found {len(matches)}")
    return matches[0]


def archive(name, object_dir):
    output = STAGE / "libraries" / name / "lib_brotli.a"
    output.parent.mkdir(parents=True, exist_ok=True)
    objects = sorted(object_dir.rglob("*.o"))
    if not objects:
        raise SystemExit(f"No object files under {object_dir}; build the wheel first")
    subprocess.run(["/usr/bin/libtool", "-static", "-o", output, *objects], check=True)
    return output


def main():
    if STAGE.exists():
        shutil.rmtree(STAGE)
    # Extract the Python facade from the verified wheel; native code is linked
    # statically and registered with PyImport_AppendInittab.
    facade_wheels = WHEELS / "macos-universal2"
    if not list(facade_wheels.glob("*.whl")):
        facade_wheels = WHEELS / "ios-arm64"
    extension(facade_wheels, STAGE / "unused-extension")
    build = ROOT / ".native-build/native-src/brotli/bin"
    libraries = [
        archive("ios-arm64", build / "temp.ios-13.0-arm64-iphoneos-cpython-314"),
        archive("ios-simulator-arm64", build / "temp.ios-13.0-arm64-iphonesimulator-cpython-314"),
        archive("ios-simulator-x86_64", build / "temp.ios-13.0-x86-64-iphonesimulator-cpython-314"),
        archive("macos-universal2", one_directory("temp.macosx-*-arm64-cpython-314")),
    ]
    simulator = STAGE / "libraries/ios-simulator/lib_brotli.a"
    simulator.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["lipo", "-create", libraries[1], libraries[2], "-output", simulator], check=True)
    libraries = [libraries[0], simulator, *libraries[3:]]
    headers = STAGE / "headers"
    headers.mkdir()
    (headers / "brotli_module.h").write_text("void *PyInit__brotli(void);\n")
    if OUTPUT.exists():
        shutil.rmtree(OUTPUT)
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    command = ["xcodebuild", "-create-xcframework"]
    for item in libraries:
        command += ["-library", str(item), "-headers", str(headers)]
    subprocess.run(command + ["-output", str(OUTPUT)], check=True)
    subprocess.run(["plutil", "-lint", str(OUTPUT / "Info.plist")], check=True)
    print(f"Created {OUTPUT}")


if __name__ == "__main__":
    main()
