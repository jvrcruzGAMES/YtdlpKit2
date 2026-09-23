# Runtime architecture

## Lifecycle

`PythonRuntimeState` moves from `uninitialized` to `starting`, then to either
`ready` or `failed(message)`. CPython is process-global and is deliberately not
finalized during normal application life; `shuttingDown` reserves the state
needed for a future controlled teardown. A failed process-global interpreter
start remains failed, while a successful start is a no-op on subsequent calls.

CPython calls from Swift remain actor-serialized. Python-created threads may be
supported later, but this does not permit `PythonObject` values to escape the
runtime actor.

Asynchronous wheel retrieval happens before CPython starts. After bootstrap,
the initializing thread releases the GIL. Every subsequent actor-serialized
operation acquires and releases it through the C boundary, making Swift
executor thread migration safe. Work is not main-actor isolated. Multiple
operations are intentionally serialized for now; an interpreter pool can
replace this policy without changing the public API.

## Search paths

The initial managed paths are the bundled bridge module directory, writable
`site-packages`, plugins, packages, and explicitly configured directories.
They are standardized, symlinks are resolved, duplicates are removed, and the
ordered values are inserted into `sys.path`. CPython's own standard-library
paths remain available from its bundled home. Host `PYTHONPATH` is not used.

## Native boundary

`YtdlpKit2_RegisterNativePythonModules` registers modules with
`PyImport_AppendInittab` after PythonKit loads the bundled image and before the
first Python access initializes CPython. `_ytdlpkit_native` currently exposes
`log`, `bridge_version`, `runtime_root`, structured event/log emission, and
cancellation queries. Future ffmpeg and ffprobe callbacks use this same ABI.

Callbacks carry only an operation UUID and JSON. A locked Swift registry maps
the ID to bounded `AsyncStream` storage and cancellation state. Python throttles
progress to roughly five updates per second while preserving final updates.

The C target resolves CPython symbols from the selected process-global image.
This avoids compile-time coupling to a host Python SDK while still executing a
real CPython extension in process.

## Distribution boundary

Maintainers build and verify CPython XCFrameworks separately. The Swift package
conditionally includes the local artifacts so source-only foundation builds
remain possible, but `prepare()` never claims readiness without the signed
runtime. Release automation must stage the interpreter, runtime resource tree,
and `Native/PythonStdlibExtensions` before archiving the package. CPython's
compiled standard-library modules are signed iOS frameworks; resource bundles
contain only Python/data files and framework markers. The runtime manifest's major/minor version must
match the interpreter.

yt-dlp is not a package resource. `YtdlpPackageManager` downloads its pinned
pure-Python wheel from PyPI, verifies the published hash, and atomically commits
it to the shared `packages/installed` site-packages root. The same transaction engine installs packaging,
dependencies, and user distributions without changing extraction APIs.
