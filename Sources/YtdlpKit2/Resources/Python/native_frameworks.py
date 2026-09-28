"""Import wheel extensions relocated into app-signed Apple frameworks."""

import importlib.abc
import importlib.machinery
import importlib.util
import os
from pathlib import Path
import sys


def framework_binary(marker):
    marker = Path(marker).resolve()
    relative = Path(marker.read_text().strip())
    stem = marker.name.split(".")[0]
    is_stdlib = "PythonStdlib_" in str(relative) or marker.parent.name == "lib-dynload"

    roots = [Path(value) for value in os.environ.get("YTDLPKIT_FRAMEWORK_PATHS", "").split(os.pathsep) if value]
    roots.extend((Path(sys.executable).parent, Path(sys.executable).parent / "Frameworks"))
    cur = marker.parent
    for _ in range(10):
        roots.extend((cur, cur / "Frameworks", cur / "Native/PythonExtensions", cur / "Native/PythonStdlibExtensions"))
        cur = cur.parent

    # On macOS, standard library extensions are in Python.framework/Versions/3.14/lib/python3.14/lib-dynload/*.so
    if sys.platform == "darwin" and is_stdlib:
        for root in roots:
            for base in (root, root / "Python.framework", root.parent / "Python.framework",
                         root / "Native/CPython/Python.xcframework/macos-arm64_x86_64/Python.framework"):
                dynload = base / "Versions/3.14/lib/python3.14/lib-dynload"
                if dynload.is_dir():
                    for candidate in dynload.glob(f"{stem}*.so"):
                        if candidate.is_file() and candidate.name.split(".")[0] == stem:
                            return candidate

    framework = relative.parts[-2]
    executable = relative.parts[-1]
    module_name = framework[:-len(".framework")] if framework.endswith(".framework") else framework

    for root in roots:
        if sys.platform == "darwin" and "ios-" in str(root):
            continue
        for candidate in (root / relative, root / framework / executable, root / f"{executable}.framework" / executable):
            if candidate.is_file() and not (sys.platform == "darwin" and "ios-" in str(candidate)):
                return candidate

        for xcframework_dir in (root / f"{module_name}.xcframework",
                                root / "Native/PythonExtensions" / f"{module_name}.xcframework",
                                root / "Native/PythonStdlibExtensions" / f"{module_name}.xcframework"):
            if xcframework_dir.is_dir():
                slices = ("macos-arm64_x86_64", "macos-arm64", "macos") if sys.platform == "darwin" else ("ios-arm64", "ios-arm64_x86_64-simulator")
                for slice_name in slices:
                    candidate = xcframework_dir / slice_name / framework / executable
                    if candidate.is_file():
                        return candidate

        if sys.platform == "darwin":
            for base in (root, root / "Python.framework", root.parent / "Python.framework"):
                dynload = base / "Versions/3.14/lib/python3.14/lib-dynload"
                if dynload.is_dir():
                    for candidate in dynload.glob(f"{stem}*.so"):
                        if candidate.is_file() and candidate.name.split(".")[0] == stem:
                            return candidate
    raise ImportError(f"Signed framework for {marker} is not embedded")


class FrameworkFinder(importlib.abc.MetaPathFinder):
    def find_spec(self, fullname, path=None, target=None):
        leaf = fullname.rsplit(".", 1)[-1]
        roots = [Path(item) for item in (path or sys.path) if isinstance(item, str)]
        if path is None and "." in fullname:
            relative = Path(*fullname.split("."))
            roots = [Path(item) / relative.parent for item in sys.path if isinstance(item, str)]
        for root in roots:
            markers = sorted(root.glob(f"{leaf}*.fwork"))
            if markers:
                try:
                    binary = framework_binary(markers[0])
                    loader = importlib.machinery.ExtensionFileLoader(fullname, str(binary))
                    return importlib.util.spec_from_file_location(fullname, binary, loader=loader)
                except ImportError:
                    pass
            if any((root / f"{leaf}{suffix}").is_file()
                   for suffix in importlib.machinery.EXTENSION_SUFFIXES):
                return None
        if sys.platform == "darwin":
            framework_paths = [Path(v) for v in os.environ.get("YTDLPKIT_FRAMEWORK_PATHS", "").split(os.pathsep) if v]
            for val in framework_paths:
                for base in (val, val / "Python.framework", val.parent / "Python.framework"):
                    dynload = base / "Versions/3.14/lib/python3.14/lib-dynload"
                    if dynload.is_dir():
                        for suffix in importlib.machinery.EXTENSION_SUFFIXES:
                            candidate = dynload / f"{leaf}{suffix}"
                            if candidate.is_file():
                                loader = importlib.machinery.ExtensionFileLoader(fullname, str(candidate))
                                return importlib.util.spec_from_file_location(fullname, candidate, loader=loader)
        return None


def install():
    if not any(isinstance(finder, FrameworkFinder) for finder in sys.meta_path):
        sys.meta_path.insert(0, FrameworkFinder())


def load_extension(fullname):
    """Load a relocated extension without importing its parent package."""
    if fullname in sys.modules:
        return sys.modules[fullname]
    leaf = fullname.rsplit(".", 1)[-1]
    for root in [Path(item) / Path(*fullname.split(".")[:-1]) for item in sys.path if isinstance(item, str)]:
        binaries = [root / f"{leaf}{suffix}" for suffix in importlib.machinery.EXTENSION_SUFFIXES]
        binaries = [binary for binary in binaries if binary.is_file()]
        markers = sorted(root.glob(f"{leaf}*.fwork"))
        if binaries or markers:
            binary = None
            if markers:
                try:
                    binary = framework_binary(markers[0])
                except ImportError:
                    binary = binaries[0] if binaries else None
            else:
                binary = binaries[0]
            if binary is None:
                continue
            loader = importlib.machinery.ExtensionFileLoader(fullname, str(binary))
            spec = importlib.util.spec_from_file_location(fullname, binary, loader=loader)
            module = importlib.util.module_from_spec(spec)
            sys.modules[fullname] = module
            loader.exec_module(module)
            return module
    raise ImportError(f"No bundled framework marker for {fullname}")
