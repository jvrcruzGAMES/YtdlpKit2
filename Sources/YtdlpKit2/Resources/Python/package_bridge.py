import configparser
import csv
import email.parser
import json
import os
import pathlib
import shutil
import tarfile
import tomllib
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


def _source_project(archive_path, fallback_version):
    with tarfile.open(archive_path, "r:*") as archive:
        files = [member for member in archive.getmembers() if member.isfile()]
        pyprojects = [member for member in files if member.name.count("/") == 1
                      and member.name.endswith("/pyproject.toml")]
        if len(pyprojects) != 1:
            raise ValueError("Git package must have one root pyproject.toml")
        root = pyprojects[0].name.rsplit("/", 1)[0]
        stream = archive.extractfile(pyprojects[0])
        if stream is None:
            raise ValueError("Git package pyproject.toml is unreadable")
        document = tomllib.loads(stream.read().decode("utf-8"))
        project = document.get("project", {})
        name = project.get("name")
        if not name:
            raise ValueError("Git package requires static PEP 621 project.name")
        dynamic = set(project.get("dynamic", []))
        version = project.get("version")
        if not version:
            if "version" not in dynamic:
                raise ValueError("Git package requires a PEP 621 project.version")
            version = fallback_version
        dependencies = project.get("dependencies", [])
        if not isinstance(dependencies, list):
            raise ValueError("PEP 621 project.dependencies must be an array")
        entry_points = []
        groups = dict(project.get("entry-points", {}))
        groups["console_scripts"] = project.get("scripts", {})
        groups["gui_scripts"] = project.get("gui-scripts", {})
        for group, entries in groups.items():
            for entry_name, value in entries.items():
                entry_points.append({"group": group, "name": entry_name, "value": value})
        source_prefix = root + ("/src/" if any(
            member.name.startswith(root + "/src/") for member in files) else "/")
        relative = [member.name[len(source_prefix):] for member in files
                    if member.name.startswith(source_prefix)]
        native_files = [name for name in relative if name.lower().endswith(NATIVE_SUFFIXES)]
        top_level = sorted({parts[0] for name in relative
                            if (parts := pathlib.PurePosixPath(name).parts)
                            and not parts[0].startswith(".")
                            and (len(parts) == 1 and parts[0].endswith(".py")
                                 or len(parts) > 1 and parts[1] == "__init__.py")})
        top_level = [name[:-3] if name.endswith(".py") else name for name in top_level]
        urls = project.get("urls", {})
        metadata = {
            "name": name, "version": version, "summary": project.get("description"),
            "author": None, "license": None,
            "requiresPython": project.get("requires-python"),
            "requiresDist": dependencies, "homePage": urls.get("Homepage"),
            "projectURLs": urls, "entryPoints": entry_points,
            "topLevelModules": top_level,
        }
        return archive, root, source_prefix, metadata, native_files


def inspect_source_archive(path, fallback_version):
    try:
        archive, _, _, metadata, native_files = _source_project(path, fallback_version)
        archive.close()
        return dumps({"ok": True, "metadata": metadata, "nativeFiles": native_files,
                      "tags": ["source"], "rootIsPurelib": not native_files})
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


def extract_source_archive(path, destination, fallback_version):
    try:
        archive, _, source_prefix, metadata, native_files = _source_project(path, fallback_version)
        archive = tarfile.open(path, "r:*")
        if native_files:
            raise ValueError("Git package contains native code")
        root = pathlib.Path(destination).resolve()
        if root.exists(): shutil.rmtree(root)
        root.mkdir(parents=True)
        installed = []
        for member in archive.getmembers():
            if not member.isfile() or not member.name.startswith(source_prefix):
                continue
            relative = member.name[len(source_prefix):]
            if not relative:
                continue
            target = (root / relative).resolve()
            if root not in target.parents:
                raise ValueError(f"unsafe source member: {member.name}")
            target.parent.mkdir(parents=True, exist_ok=True)
            stream = archive.extractfile(member)
            if stream is None:
                continue
            with stream, open(target, "wb") as output:
                shutil.copyfileobj(stream, output)
            installed.append(relative)
        archive.close()
        normalized = metadata["name"].replace("-", "_")
        dist_info_name = f"{normalized}-{metadata['version']}.dist-info"
        dist_info = root / dist_info_name
        dist_info.mkdir()
        lines = ["Metadata-Version: 2.1", f"Name: {metadata['name']}",
                 f"Version: {metadata['version']}"]
        if metadata.get("requiresPython"):
            lines.append(f"Requires-Python: {metadata['requiresPython']}")
        lines.extend(f"Requires-Dist: {value}" for value in metadata["requiresDist"])
        (dist_info / "METADATA").write_text("\n".join(lines) + "\n", encoding="utf-8")
        groups = {}
        for entry in metadata["entryPoints"]:
            groups.setdefault(entry["group"], []).append(entry)
        entry_text = ""
        for group, entries in groups.items():
            entry_text += f"[{group}]\n"
            entry_text += "".join(f"{entry['name']} = {entry['value']}\n" for entry in entries)
        if entry_text:
            (dist_info / "entry_points.txt").write_text(entry_text, encoding="utf-8")
        (dist_info / "top_level.txt").write_text(
            "\n".join(metadata["topLevelModules"]) + "\n", encoding="utf-8")
        metadata_files = [str(item.relative_to(root)) for item in dist_info.iterdir()]
        installed.extend(metadata_files)
        record_name = f"{dist_info_name}/RECORD"
        with (root / record_name).open("w", encoding="utf-8", newline="") as record:
            writer = csv.writer(record)
            for name in sorted(set(installed)):
                writer.writerow((name, "", ""))
            writer.writerow((record_name, "", ""))
        installed.append(record_name)
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
