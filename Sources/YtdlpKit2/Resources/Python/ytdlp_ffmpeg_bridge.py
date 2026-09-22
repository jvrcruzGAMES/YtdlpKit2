"""Narrow yt-dlp/FFmpegKitNext interposition for the pinned yt-dlp release."""

import contextvars
import json
import os

YTDLP_FFMPEG_BRIDGE_VERSION = 1
COMPATIBLE_YTDLP = "2026.08.19"
_operation_id = contextvars.ContextVar("ytdlpkit_media_operation", default="")
_installed = False


def _normalized_ffprobe_stdout(argv, stdout):
    """Return the complete JSON document from FFprobeKit session output.

    FFprobeKit obtains stdout through its log/session plumbing. On iOS that
    stream can occasionally contain a duplicated prefix or another delivered
    log fragment. yt-dlp's metadata probes always request JSON and require a
    clean document, just like subprocess.PIPE would provide.
    """
    formats = [str(argv[index + 1]).lower()
               for index, value in enumerate(argv[:-1])
               if value in ("-of", "-print_format")]
    if not any(value == "json" or value.startswith("json=") for value in formats):
        return stdout
    try:
        json.loads(stdout)
        return stdout
    except (TypeError, ValueError):
        pass

    def balanced_json_objects(text):
        for start, character in enumerate(text):
            if character != "{":
                continue
            depth = 0
            in_string = False
            escaped = False
            for end in range(start, len(text)):
                current = text[end]
                if in_string:
                    if escaped:
                        escaped = False
                    elif current == "\\":
                        escaped = True
                    elif current == '"':
                        in_string = False
                    continue
                if current == '"':
                    in_string = True
                elif current == "{":
                    depth += 1
                elif current == "}":
                    depth -= 1
                    if depth == 0:
                        yield text[start:end + 1]
                        break

    candidates = []
    for candidate in balanced_json_objects(stdout):
        if '"streams"' not in candidate and '"format"' not in candidate:
            continue
        try:
            value = json.loads(candidate)
        except (TypeError, ValueError):
            continue
        if isinstance(value, dict) and ("streams" in value or "format" in value):
            candidates.append((len(candidate), value))
    if candidates:
        _, value = max(candidates, key=lambda item: item[0])
        return json.dumps(value, ensure_ascii=False)
    return stdout


def _execute(kind, argv):
    native = __import__("_ytdlpkit_native")
    function = native.ffmpeg if kind == "ffmpeg" else native.ffprobe
    result = json.loads(function(_operation_id.get(), json.dumps(list(argv))))
    stdout = result.get("stdout", "")
    if kind == "ffprobe" and int(result["returncode"]) == 0:
        stdout = _normalized_ffprobe_stdout(argv, stdout)
    return stdout, result.get("stderr", ""), int(result["returncode"])


def install():
    """Install only the two hooks needed by yt-dlp's FFmpeg abstraction."""
    global _installed
    if _installed:
        return
    import yt_dlp
    if yt_dlp.version.__version__ != COMPATIBLE_YTDLP:
        raise RuntimeError(
            f"FFmpeg bridge {YTDLP_FFMPEG_BRIDGE_VERSION} supports yt-dlp "
            f"{COMPATIBLE_YTDLP}, not {yt_dlp.version.__version__}")
    from yt_dlp.postprocessor import ffmpeg as module
    from yt_dlp.utils import Popen

    original_run = Popen.run

    def run(command, *args, **kwargs):
        executable = os.path.basename(str(command[0])) if command else ""
        if str(command[0]).startswith("ytdlpkit://"):
            executable = str(command[0]).split("://", 1)[1]
        if executable in ("ffmpeg", "ffprobe"):
            return _execute(executable, command[1:])
        return original_run(command, *args, **kwargs)

    def determine(_self):
        return {"ffmpeg": "ytdlpkit://ffmpeg", "ffprobe": "ytdlpkit://ffprobe"}

    def version(self, program):
        stdout, stderr, code = _execute(program, ["-version"])
        if code:
            return False, {}
        output = stdout or stderr
        # Always report the version emitted by the linked FFmpeg build.
        import re
        match = re.search(r"(?:ffmpeg|ffprobe) version\s+([^\s]+)", output)
        parsed = match.group(1) if match else None
        features = {
            "fdk": "--enable-libfdk-aac" in output,
            "setts": "setts" in output.splitlines(),
            "needs_adtstoasc": False,
        } if program == "ffmpeg" else {}
        return parsed, features

    Popen.run = staticmethod(run)
    module.FFmpegPostProcessor._determine_executables = determine
    module.FFmpegPostProcessor._get_ffmpeg_version = version
    module.FFmpegPostProcessor._version_cache = {None: None}
    module.FFmpegPostProcessor._features_cache = {}
    _installed = True


class operation:
    def __init__(self, operation_id):
        self.operation_id = operation_id
        self.token = None

    def __enter__(self):
        self.token = _operation_id.set(self.operation_id)
        return self

    def __exit__(self, *_):
        _operation_id.reset(self.token)


def validate():
    install()
    from yt_dlp.postprocessor.ffmpeg import FFmpegPostProcessor
    processor = FFmpegPostProcessor()
    return {
        "ffmpeg": processor.available,
        "ffprobe": processor.probe_available,
        "versions": processor._versions,
    }
