import json
import os
import traceback
import zipfile

from ytdlp_hooks import NativeLogger, ProgressHook, YtdlpKitCancelled
from ytdlp_serialization import dumps, normalize_media

PINNED_VERSION = "2026.08.19"


def _install_ffmpeg_bridge():
    # The Python package directory persists in Documents across app launches,
    # but monkey patches do not. Reinstall the in-process FFmpeg hooks every
    # time a fresh interpreter prepares or enters yt-dlp.
    import ytdlp_ffmpeg_bridge
    ytdlp_ffmpeg_bridge.install()


def _prepare_dynamic_plugins():
    # Managed packages can change after the interpreter and yt-dlp have already
    # initialized. Refresh immediately before an operation so installs made
    # through either the package or plugin API cannot leave yt-dlp's global
    # extractor registry stale and fall through to GenericIE.
    import ytdlp_plugin_bridge
    ytdlp_plugin_bridge._refresh()


def ensure_ytdlp(wheel_path, site_packages):
    os.makedirs(site_packages, exist_ok=True)
    try:
        import yt_dlp
        if yt_dlp.version.__version__ == PINNED_VERSION:
            _install_ffmpeg_bridge()
            return yt_dlp.version.__version__
    except (ImportError, AttributeError):
        pass
    if not os.path.isfile(wheel_path):
        raise RuntimeError(f"Bundled yt-dlp wheel is missing: {wheel_path}")
    with zipfile.ZipFile(wheel_path) as wheel:
        wheel.extractall(site_packages)
    import importlib
    importlib.invalidate_caches()
    import yt_dlp
    if yt_dlp.version.__version__ != PINNED_VERSION:
        raise RuntimeError(f"Expected yt-dlp {PINNED_VERSION}, loaded {yt_dlp.version.__version__}")
    _install_ffmpeg_bridge()
    with yt_dlp.YoutubeDL({"quiet": True}):
        pass
    return yt_dlp.version.__version__


def version():
    import yt_dlp
    return yt_dlp.version.__version__


def ffmpeg_bridge_status():
    import ytdlp_ffmpeg_bridge
    return json.dumps(ytdlp_ffmpeg_bridge.validate(), sort_keys=True)


def ffmpeg_bridge_merge(video_path, audio_path, output_path, operation_id):
    """Exercise yt-dlp's own FFmpeg command builder through the native bridge."""
    from yt_dlp.postprocessor.ffmpeg import FFmpegPostProcessor
    from ytdlp_ffmpeg_bridge import operation
    with operation(operation_id):
        FFmpegPostProcessor().run_ffmpeg_multiple_files(
            [video_path, audio_path], output_path,
            ["-map", "0:v:0", "-map", "1:a:0", "-c", "copy"])
    return output_path


def bridge_callback_test(operation_id):
    hook = ProgressHook(operation_id, minimum_interval=0)
    try:
        hook({"status": "downloading", "downloaded_bytes": 5, "total_bytes": 10})
        hook({"status": "finished", "downloaded_bytes": 10, "total_bytes": 10,
              "filename": "/tmp/ytdlpkit-callback-test.mp4"})
        NativeLogger(operation_id).warning("callback test warning")
        return "ok"
    except YtdlpKitCancelled:
        return "cancelled"


def _error(kind, exception):
    return dumps({"ok": False, "error": {"kind": kind, "message": str(exception),
                                          "traceback": traceback.format_exc()}})


def _exception_kind(exception, fallback):
    try:
        from yt_dlp import utils
        if isinstance(exception, YtdlpKitCancelled):
            return "cancelled"
        if isinstance(exception, utils.UnsupportedError):
            return "unsupported"
        if isinstance(exception, utils.GeoRestrictedError):
            return "geo_restricted"
        if isinstance(exception, (utils.DownloadError, utils.ExtractorError)):
            cause = getattr(exception, "exc_info", None)
            if cause and len(cause) > 1:
                if isinstance(cause[1], utils.UnsupportedError):
                    return "unsupported"
                if isinstance(cause[1], utils.GeoRestrictedError):
                    return "geo_restricted"
                if isinstance(cause[1], OSError):
                    return "network"
    except (ImportError, AttributeError):
        pass
    return fallback


def _options(options_json, operation_id=""):
    options = json.loads(options_json)
    options["logger"] = NativeLogger(operation_id)
    options["quiet"] = True
    options["no_warnings"] = False
    return options


def extract(url, options_json):
    try:
        _install_ffmpeg_bridge()
        _prepare_dynamic_plugins()
        from yt_dlp import YoutubeDL
        with YoutubeDL(_options(options_json)) as ydl:
            info = ydl.extract_info(url, download=False)
        return dumps({"ok": True, "value": normalize_media(info)})
    except Exception as exc:
        return _error(_exception_kind(exc, "extraction"), exc)


def _files_under(directory):
    return {os.path.realpath(os.path.join(root, name))
            for root, _, names in os.walk(directory) for name in names}


def download(url, options_json, operation_id, output_directory):
    try:
        _install_ffmpeg_bridge()
        _prepare_dynamic_plugins()
        from yt_dlp import YoutubeDL
        if __import__("_ytdlpkit_native").is_cancelled(operation_id):
            raise YtdlpKitCancelled("download cancelled")
        before = _files_under(output_directory)
        options = _options(options_json, operation_id)
        options["progress_hooks"] = [ProgressHook(operation_id)]
        from ytdlp_ffmpeg_bridge import operation
        with operation(operation_id), YoutubeDL(options) as ydl:
            info = ydl.extract_info(url, download=True)
            primary = ydl.prepare_filename(info) if isinstance(info, dict) else None
        files = sorted(_files_under(output_directory) - before)
        if primary and os.path.exists(primary) and os.path.realpath(primary) not in files:
            files.append(os.path.realpath(primary))
        return dumps({"ok": True, "value": {"mediaInfo": normalize_media(info),
                     "files": files, "primaryFile": primary if primary and os.path.exists(primary) else None}})
    except YtdlpKitCancelled as exc:
        return _error("cancelled", exc)
    except Exception as exc:
        return _error(_exception_kind(exc, "download"), exc)
