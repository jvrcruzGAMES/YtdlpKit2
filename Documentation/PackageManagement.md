# Package management and native-code policy

`YtdlpPackageManager` resolves PyPI metadata without invoking pip. Downloads
are SHA-256 verified and cached, wheels are inspected through embedded Python,
and each distribution is extracted into a private staging root. A candidate
site-packages tree is atomically committed at `packages/installed` and then
recorded in `metadata/packages-v1.json`.

The shared root has standard Python `site-packages` semantics, so importlib,
distribution metadata, and yt-dlp plugin discovery can see every installed
distribution. The database tracks file-level ownership for exact uninstall and
collision detection. Candidate-tree replacement preserves transaction rollback,
and only the shared root is inserted into the controlled `sys.path`.

Project names use PEP 503 normalization. The runtime-managed `packaging`
distribution evaluates PEP 440 specifiers, PEP 508 requirements, and markers.
yt-dlp and packaging are protected core packages installed through the same
transaction engine as user packages; neither is bundled with the library.

Downloaded wheel members ending in `.so`, `.dylib`, `.bundle`, `.pyd`, or
`.dll`, and non-pure wheel metadata, trigger native compatibility checks. With
the default `bundledOnly` policy, installation succeeds only when
`native-packages.json` matches distribution version and `cp314`; downloaded
binaries are then omitted during extraction. The current manifest intentionally
declares Brotli, pycryptodomex, CFFI, cryptography, curl-cffi, and ada-url as
native packages whose signed framework artifacts must be staged.

Pure-Python PyPI and GitHub packages recursively install applicable
`Requires-Dist` dependencies. GitHub sources are built through their declared
PEP 517 backend (including managed installation of `build-system.requires`),
then inspected and installed from the resulting wheel just like a PyPI wheel.
Sources containing native binaries and builds that produce a non-pure wheel
are rejected. GitHub requirements are resolved to immutable
commits, SHA-256 verified, and accepted only when a source archive has static
PEP 621 metadata and contains no native code. Runtime compilation and arbitrary
PEP 517 build backends remain unsupported on iOS.

Managed packages and plugins default to `Documents/YtdlpKit2`. An existing
default installation under Application Support is moved there once, before the
runtime creates its directories. A caller-supplied `applicationSupportDirectory`
continues to override the base directory.
