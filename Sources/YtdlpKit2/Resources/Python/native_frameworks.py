"""Import wheel extensions relocated into app-signed Apple frameworks."""

import importlib.abc
import importlib.machinery
import importlib.util
import os
from pathlib import Path
import sys


def framework_binary(marker):
    marker = Path(marker)
    relative = Path(marker.read_text().strip())
    roots = [Path(value) for value in os.environ.get("YTDLPKIT_FRAMEWORK_PATHS", "").split(os.pathsep) if value]
    roots.extend((Path(sys.executable).parent, Path(sys.executable).parent / "Frameworks"))
    framework = relative.parts[-2]
    executable = relative.parts[-1]
    for root in roots:
        for candidate in (root / relative, root / framework / executable):
            if candidate.is_file():
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
            if markers and sys.platform == "ios":
                binary = framework_binary(markers[0])
                loader = importlib.machinery.ExtensionFileLoader(fullname, str(binary))
                return importlib.util.spec_from_file_location(fullname, binary, loader=loader)
            if any((root / f"{leaf}{suffix}").is_file()
                   for suffix in importlib.machinery.EXTENSION_SUFFIXES):
                return None
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
            # A marker represents the signed iOS image. Prefer it over the
            # colocated macOS .so included for the macOS runtime slice.
            binary = (framework_binary(markers[0])
                      if markers and sys.platform == "ios" else binaries[0])
            loader = importlib.machinery.ExtensionFileLoader(fullname, str(binary))
            spec = importlib.util.spec_from_file_location(fullname, binary, loader=loader)
            module = importlib.util.module_from_spec(spec)
            sys.modules[fullname] = module
            loader.exec_module(module)
            return module
    raise ImportError(f"No bundled framework marker for {fullname}")
