# YtdlpKit2

YtdlpKit2 provides an in-process yt-dlp runtime for iOS and macOS. It owns
CPython, isolates PythonKit, and exposes typed metadata, download, progress,
and cancellation APIs, plus separate Python-package and yt-dlp-plugin
management. FFmpeg-dependent processing uses a separately built, signed
FFmpegKitNext artifact; no standalone FFmpeg executable is spawned.

```swift
import YtdlpKit2

try await YtdlpKit.shared.prepare()
let status = await YtdlpKit.shared.runtimeStatus()
print(status.pythonVersion ?? "unavailable")
```

## Extract and download

yt-dlp is not bundled. `prepare()` uses `YtdlpPackageManager` to resolve its
pinned pure-Python wheel, verify its index-provided SHA-256, transactionally
install it into the managed `packages/installed` site-packages root, import it, and check its reported
version. No executable or native code is downloaded.

```swift
let info = try await YtdlpKit.shared.extractInfo(from: videoURL)
for format in info.formats {
    print(format.formatID, format.extension ?? "")
}

let task = try await YtdlpKit.shared.startDownload(
    YtdlpRequest(url: videoURL, outputDirectory: destination, format: .best)
)
for await event in task.events {
    if case let .progress(progress) = event {
        print(progress.fractionCompleted ?? 0)
    }
}
let result = try await task.value
```

Call `await task.cancel()` to cancel in process. Formats that explicitly
require FFmpeg merging are rejected until a media-processing provider exists.

## Architecture

`YtdlpKit` is the public actor. It owns one `PythonRuntime` actor, which
serializes every Swift-originated CPython call. `PythonBridge` is internal and
is the only layer that handles PythonKit values. Python invokes native services
through `_ytdlpkit_native`, a statically registered CPython extension. That
extension crosses a C ABI rather than retaining Swift objects.

Startup creates the writable environment, validates the runtime manifest,
loads the bundled CPython image, registers native modules before interpreter
initialization, configures `sys.path`, imports standard-library and bundled
modules, exercises both bridges, and only then changes state to `ready`.
Actor isolation makes repeated or concurrent `prepare()` calls idempotent.

PythonKit is an implementation detail. It resolves symbols from the exact
bundled library selected by `RuntimeBootstrap`; public APIs contain ordinary
Swift values only.

## Filesystem layout

The writable container uses `Application Support/YtdlpKit2`:

```text
runtime/
python/site-packages/
packages/
plugins/
cache/
temp/
metadata/
logs/
```

Bundled standard-library files and bridge modules remain read-only resources.
Downloaded content is limited to interpreted Python and data under the
writable directories. No runtime step invokes a shell, writes an executable,
changes executable permissions, forks, or loads downloaded Mach-O code.

## Why YtdlpKit2 does not use system Python

iOS does not provide a supported application Python runtime, and a
macOS user's interpreter is neither stable nor controlled by the application.
YtdlpKit2 therefore loads only its signed, bundled CPython 3.14 framework. If
that artifact is missing, preparation fails explicitly with `runtimeNotFound`;
it never searches Homebrew, `/usr/bin`, `PATH`, or `PYTHONPATH`.

## Why native Python extensions must be bundled

Apple platform code signing prevents an application from downloading and
loading new machine code. CPython itself, its compiled standard-library
modules, and every future binary Python dependency must be compiled ahead of
time, included in the application bundle, and signed with the app. Runtime
package installation can safely install only pure Python and data.
The native module registry is the single expansion point for those extensions.

## Building CPython artifacts

The maintained runtime is CPython 3.14 (`cp314`). The build wrapper uses the
BeeWare Python Apple Support cross-build, which produces real Apple SDK slices:

```sh
export YTDLPKIT_XCFRAMEWORK_SIGN_IDENTITY="Apple Distribution: Example, Inc. (TEAMID1234)"
Scripts/build-python.sh
Scripts/package-python-runtime.sh .native-build/python-apple-support/dist
Scripts/verify-python-runtime.sh
```

The signing identity is required for standard-library XCFrameworks that include
OpenSSL/BoringSSL code, such as `_ssl` and `_hashlib`. Those XCFrameworks also
receive `PrivacyInfo.xcprivacy` manifests during packaging.

The packaging step copies the complete Python standard library into the runtime
resource tree. It also converts compiled standard-library modules such as
`math`, `_ssl`, `_hashlib`, `_socket`, `sqlite3`, `lzma`, and `bz2` into signed
iOS XCFrameworks under `Native/PythonStdlibExtensions`; no Mach-O binaries
remain in the resource bundle.

`Package.swift` automatically detects both `Native/CPython/Python.xcframework`
and the generated standard-library extension XCFrameworks. Release archives
must stage this complete artifact set and include macOS, iOS device, and iOS
simulator slices. Consumers link the prebuilt artifacts; they do not compile
CPython.

## Building native Python packages

The native-package set is Brotli 1.2.0, cffi 2.0.0, cryptography 48.0.0,
curl-cffi 0.16.2, pycryptodomex 3.23.0, and ada-url 4.0.0. Their artifacts and checksums are
pinned. The build emits a static `_brotli.xcframework`, iOS XCFrameworks for
each loadable extension, and macOS extension bundles. It does not bundle
yt-dlp or unrelated pure-Python distributions.

```sh
Scripts/build-python.sh
Scripts/build-native-packages.py --build
swift test
```

The verified or source-verified wheels for `cffi`, `cryptography`, `curl-cffi`,
`pycryptodomex`, and `ada-url` are converted into per-extension XCFrameworks for iOS device
and simulator. Pure transitive dependencies such as `pycparser`
are not bundled; the package manager may install those interpreted dependencies
at runtime. `certifi` is an explicit pinned runtime-core dependency because
embedded OpenSSL cannot use the iOS system trust store as a filesystem CA
bundle. The other pure-Python yt-dlp defaults (`requests`, `urllib3`, `idna`,
`charset-normalizer`, `mutagen`, and `websockets`) are also pinned and managed
as runtime-core packages.

## Testing

```sh
swift build
swift test
```

Foundation tests run without a binary artifact. In-process integration tests
are enabled in release/CI jobs that first stage `Python.xcframework`; those
tests must not be replaced with a host-Python fallback. The separate native
workflow rebuilds artifacts manually so routine CI does not rebuild CPython.

See [Architecture.md](Documentation/Architecture.md) for lifecycle and release
details and [PackageManagement.md](Documentation/PackageManagement.md) for the
installer and native-code policy. See [PluginManagement.md](Documentation/PluginManagement.md)
for plugin discovery, Apple WebKit JSI, and security behavior.
See [FFmpeg.md](Documentation/FFmpeg.md) for the in-process media bridge,
licensing profile, and maintainer build procedure.
