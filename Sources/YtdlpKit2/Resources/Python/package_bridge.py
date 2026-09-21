import configparser
import email.parser
import json
import os
import pathlib
import shutil
import zipfile

from ytdlp_serialization import dumps

NATIVE_SUFFIXES = (".so", ".dylib", ".bundle", ".pyd", ".dll")


def _dist_info(names):
    candidates = sorted({n.split("/", 1)[0] for n in names if ".dist-info/" in n})
    if len(candidates) != 1:
        raise ValueError("wheel must contain exactly one .dist-info directory")
    return candidates[0]


def _read_text(wheel, name):
    try:
        return wheel.read(name).decode("utf-8", "replace")
    except KeyError:
        return ""


def inspect_wheel(path):
    try:
        with zipfile.ZipFile(path) as wheel:
            names = wheel.namelist()
            dist_info = _dist_info(names)
            message = email.parser.Parser().parsestr(_read_text(wheel, f"{dist_info}/METADATA"))
            wheel_metadata = email.parser.Parser().parsestr(_read_text(wheel, f"{dist_info}/WHEEL"))
            entry_points = []
            parser = configparser.ConfigParser()
            parser.read_string(_read_text(wheel, f"{dist_info}/entry_points.txt") or "")
            for group in parser.sections():
                for name, value in parser.items(group):
                    entry_points.append({"group": group, "name": name, "value": value})
            top_level = [x.strip() for x in _read_text(
                wheel, f"{dist_info}/top_level.txt").splitlines() if x.strip()]
            project_urls = {}
            for value in message.get_all("Project-URL", []):
                if "," in value:
                    key, url = value.split(",", 1); project_urls[key.strip()] = url.strip()
            native_files = [n for n in names if n.lower().endswith(NATIVE_SUFFIXES)]
            tags = wheel_metadata.get_all("Tag", [])
            metadata = {
                "name": message.get("Name") or "", "version": message.get("Version") or "",
                "summary": message.get("Summary"), "author": message.get("Author"),
                "license": message.get("License"), "requiresPython": message.get("Requires-Python"),
                "requiresDist": message.get_all("Requires-Dist", []),
                "homePage": message.get("Home-page"), "projectURLs": project_urls,
                "entryPoints": entry_points, "topLevelModules": top_level,
            }
            return dumps({"ok": True, "metadata": metadata, "nativeFiles": native_files,
                          "tags": tags, "rootIsPurelib": wheel_metadata.get("Root-Is-Purelib") == "true"})
    except Exception as exc:
        return dumps({"ok": False, "error": str(exc)})


def extract_wheel(path, destination, strip_native):
    try:
        root = pathlib.Path(destination).resolve()
        if root.exists(): shutil.rmtree(root)
        root.mkdir(parents=True)
        installed = []
        with zipfile.ZipFile(path) as wheel:
            dist_info = _dist_info(wheel.namelist())
            data_prefix = dist_info[:-len(".dist-info")] + ".data/"
            for info in wheel.infolist():
                name = info.filename
                if name.endswith("/"): continue
                if strip_native and name.lower().endswith(NATIVE_SUFFIXES): continue
                target_name = name
                if name.startswith(data_prefix):
                    category, _, remainder = name[len(data_prefix):].partition("/")
                    if category in ("purelib", "platlib", "data"):
                        target_name = remainder
                    else:
                        # Wheel scripts, headers, and configuration executables
                        # are not runtime-importable package content.
                        continue
                target = (root / target_name).resolve()
                if root not in target.parents:
                    raise ValueError(f"unsafe wheel member: {name}")
                target.parent.mkdir(parents=True, exist_ok=True)
                with wheel.open(info) as source, open(target, "wb") as output:
                    shutil.copyfileobj(source, output)
                installed.append(target_name)
        return dumps({"ok": True, "files": installed})
    except Exception as exc:
        return dumps({"ok": False, "error": str(exc)})


def add_search_path(path):
    import sys
    normalized = os.path.realpath(path)
    if normalized not in sys.path: sys.path.insert(0, normalized)


def remove_search_path(path):
    import sys
    normalized = os.path.realpath(path)
    sys.path[:] = [p for p in sys.path if os.path.realpath(p) != normalized]


def validate_imports(modules):
    import importlib
    for module in modules[:3]:
        importlib.import_module(module)
    return True


def parse_requirement(requirement, environment_json):
    from packaging.requirements import Requirement
    parsed = Requirement(requirement)
    environment = json.loads(environment_json)
    applies = parsed.marker is None or parsed.marker.evaluate(environment)
    return dumps({"name": parsed.name, "specifier": str(parsed.specifier),
                  "url": parsed.url, "applies": applies})


def select_version(versions, specifier, allow_prereleases):
    from packaging.specifiers import SpecifierSet
    from packaging.version import Version, InvalidVersion
    constraint = SpecifierSet(specifier, prereleases=allow_prereleases)
    valid = []
    for value in versions:
        try:
            version = Version(value)
            if version in constraint and (allow_prereleases or not version.is_prerelease):
                valid.append((version, value))
        except InvalidVersion:
            pass
    return max(valid)[1] if valid else ""
