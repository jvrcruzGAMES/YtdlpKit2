import base64
import json
import os


def json_safe(value, seen=None):
    if seen is None:
        seen = set()
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    identity = id(value)
    if identity in seen:
        return "<recursive>"
    seen.add(identity)
    try:
        if isinstance(value, bytes):
            return {"$bytes_base64": base64.b64encode(value).decode("ascii")}
        if isinstance(value, os.PathLike):
            return os.fspath(value)
        if isinstance(value, dict):
            return {str(k): json_safe(v, seen) for k, v in value.items()}
        if isinstance(value, (list, tuple, set, frozenset)):
            return [json_safe(v, seen) for v in value]
        return str(value)
    finally:
        seen.discard(identity)


def _subtitle_tracks(value):
    return [
        {"language": language, "formats": [
            {"url": item.get("url"), "extension": item.get("ext"), "name": item.get("name")}
            for item in (formats or []) if isinstance(item, dict)
        ]}
        for language, formats in (value or {}).items()
    ]


def normalize_media(info):
    if not isinstance(info, dict):
        return None
    entries = info.get("entries")
    return {
        "id": info.get("id"), "title": info.get("title"),
        "description": info.get("description"), "webpageURL": info.get("webpage_url"),
        "originalURL": info.get("original_url"), "extractor": info.get("extractor"),
        "extractorKey": info.get("extractor_key"), "uploader": info.get("uploader"),
        "uploaderID": info.get("uploader_id"), "channel": info.get("channel"),
        "channelID": info.get("channel_id"), "duration": info.get("duration"),
        "timestamp": info.get("timestamp"), "uploadDate": info.get("upload_date"),
        "viewCount": info.get("view_count"), "likeCount": info.get("like_count"),
        "commentCount": info.get("comment_count"), "ageLimit": info.get("age_limit"),
        "liveStatus": info.get("live_status"), "isLive": info.get("is_live"),
        "wasLive": info.get("was_live"), "thumbnailURL": info.get("thumbnail"),
        "thumbnails": [{
            "url": x.get("url"), "id": x.get("id"), "width": x.get("width"),
            "height": x.get("height"), "preference": x.get("preference"),
            "resolution": x.get("resolution")
        } for x in (info.get("thumbnails") or []) if isinstance(x, dict) and x.get("url")],
        "formats": [{
            "formatID": x.get("format_id") or "", "formatNote": x.get("format_note"),
            "extension": x.get("ext"), "protocol": x.get("protocol"), "url": x.get("url"),
            "width": x.get("width"), "height": x.get("height"), "fps": x.get("fps"),
            "videoCodec": x.get("vcodec"), "audioCodec": x.get("acodec"),
            "videoBitrate": x.get("vbr"), "audioBitrate": x.get("abr"),
            "totalBitrate": x.get("tbr"), "filesize": x.get("filesize"),
            "filesizeApprox": x.get("filesize_approx"), "audioSampleRate": x.get("asr"),
            "audioChannels": x.get("audio_channels"), "dynamicRange": x.get("dynamic_range"),
            "language": x.get("language"), "quality": x.get("quality"),
            "preference": x.get("preference"), "sourcePreference": x.get("source_preference"),
            "container": x.get("container")
        } for x in (info.get("formats") or []) if isinstance(x, dict)],
        "subtitles": _subtitle_tracks(info.get("subtitles")),
        "automaticCaptions": _subtitle_tracks(info.get("automatic_captions")),
        "chapters": [{"title": x.get("title"), "startTime": x.get("start_time") or 0,
                      "endTime": x.get("end_time")}
                     for x in (info.get("chapters") or []) if isinstance(x, dict)],
        "playlistID": info.get("playlist_id") or (info.get("id") if info.get("_type") == "playlist" else None),
        "playlistTitle": info.get("playlist_title") or (info.get("title") if info.get("_type") == "playlist" else None),
        "playlistIndex": info.get("playlist_index"),
        "entries": ([normalize_media(x) for x in entries if isinstance(x, dict)]
                    if entries is not None else None),
        "rawJSON": json_safe(info),
    }


def dumps(value):
    return json.dumps(json_safe(value), ensure_ascii=False, allow_nan=False)
