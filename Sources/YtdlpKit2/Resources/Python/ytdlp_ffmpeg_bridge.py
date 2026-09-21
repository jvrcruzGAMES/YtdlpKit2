"""Narrow yt-dlp/FFmpegKitNext interposition for the pinned yt-dlp release."""

import contextvars
import json
import os

YTDLP_FFMPEG_BRIDGE_VERSION = 1
COMPATIBLE_YTDLP = "2026.08.19"
_operation_id = contextvars.ContextVar("ytdlpkit_media_operation", default="")
_installed = False


def _execute(kind, argv):
    native = __import__("_ytdlpkit_native")
    function = native.ffmpeg if kind == "ffmpeg" else native.ffprobe
    result = json.loads(function(_operation_id.get(), json.dumps(list(argv))))
    return result.get("stdout", ""), result.get("stderr", ""), int(result["returncode"])


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
