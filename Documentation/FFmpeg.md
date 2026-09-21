# In-process FFmpeg architecture

YtdlpKit2 supports iOS/iPadOS and macOS. Applications do not install an
FFmpeg executable and the runtime never downloads native media code.
Maintainers build the pinned FFmpegKitNext source once; applications link the
resulting signed XCFrameworks through SwiftPM.

```text
yt-dlp FFmpegPostProcessor
  -> ytdlp_ffmpeg_bridge.py
  -> _ytdlpkit_native (JSON C ABI, GIL released)
  -> MediaProcessingProvider
  -> FFmpegKitMediaProcessingProvider
  -> FFmpegKitNext / FFmpeg
```

The Python bridge patches only yt-dlp's executable discovery/version method
and its `Popen.run` calls whose executable is the `ytdlpkit://ffmpeg` or
`ytdlpkit://ffprobe` sentinel. All unrelated subprocess behavior remains
unchanged. yt-dlp remains responsible for media-operation arguments.

Arguments cross the boundary as a JSON array and go to the upstream
argument-array API; no shell string is constructed. The C extension releases
the CPython GIL during native execution and reacquires it before returning.
Security-scoped output access remains alive until the download and its
post-processing finish.

## Building

The release build is pinned to FFmpegKitNext 9.0.0 commit
`a724ed99583dcfe2af497c794fdd6b24ddd54a4e`, FFmpeg 9.0.1, and the upstream
`xcode26` Nix profile.

```sh
Scripts/build-ffmpeg-kit-next.sh
Scripts/verify-ffmpeg-kit-next.sh
swift test
```

It covers iOS device arm64, iOS Simulator arm64/x86_64, and macOS
arm64/x86_64. AudioToolbox, AVFoundation, VideoToolbox, bzip2, and zlib are
enabled. The default has no GPL-only external library and uses LGPL-3.0.
Enabling a GPL library requires a distinct artifact and GPL-3.0 compliance
review.

FFmpegKitNext publishes no binary package, so maintainers need its supported
Nix toolchain. Consuming apps do not. If artifacts are absent, capability
checks report unavailable and native replacements are never downloaded.

Paths remain individual argv elements, so spaces, apostrophes, Unicode, emoji,
and parentheses require no shell escaping. Apple sandbox rules still apply.
Background execution is controlled by the host app; YtdlpKit2 adds no hidden
background modes.
