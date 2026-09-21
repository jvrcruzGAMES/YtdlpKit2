import json
import time

import _ytdlpkit_native


class YtdlpKitCancelled(Exception):
    pass


class ProgressHook:
    def __init__(self, operation_id, minimum_interval=0.2):
        self.operation_id = operation_id
        self.minimum_interval = minimum_interval
        self.last_emit = 0.0
        self.started = False

    def __call__(self, data):
        if _ytdlpkit_native.is_cancelled(self.operation_id):
            raise YtdlpKitCancelled("download cancelled")
        status = data.get("status", "unknown")
        now = time.monotonic()
        final = status in ("finished", "error")
        if not self.started:
            self.started = True
            self._emit({"type": "started"})
        if not final and now - self.last_emit < self.minimum_interval:
            return
        self.last_emit = now
        progress = {
            "status": status, "filename": data.get("filename"),
            "temporaryFilename": data.get("tmpfilename"),
            "downloadedBytes": data.get("downloaded_bytes"),
            "totalBytes": data.get("total_bytes"),
            "estimatedTotalBytes": data.get("total_bytes_estimate"),
            "speedBytesPerSecond": data.get("speed"), "eta": data.get("eta"),
            "elapsed": data.get("elapsed"), "fragmentIndex": data.get("fragment_index"),
            "fragmentCount": data.get("fragment_count"),
        }
        self._emit({"type": "progress", "progress": progress})
        if status == "finished" and data.get("filename"):
            self._emit({"type": "file", "path": data["filename"]})

    def _emit(self, payload):
        _ytdlpkit_native.emit_download_event(self.operation_id, json.dumps(payload))


class NativeLogger:
    def __init__(self, operation_id=""):
        self.operation_id = operation_id

    def debug(self, message):
        if not str(message).startswith("[debug]"):
            self.info(message)
        else:
            self._emit("debug", message)

    def info(self, message): self._emit("info", message)
    def warning(self, message): self._emit("warning", message)
    def error(self, message): self._emit("error", message)

    def _emit(self, level, message):
        _ytdlpkit_native.emit_log(self.operation_id, level, str(message))
