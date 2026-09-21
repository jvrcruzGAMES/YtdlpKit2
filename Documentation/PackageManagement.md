# Package management and native-code policy

`YtdlpPackageManager` resolves PyPI metadata without invoking pip. Downloads
are SHA-256 verified and cached, wheels are inspected through embedded Python,
and each distribution is extracted into a private staging root. A validated
root is atomically renamed into `packages/installed/<normalized>/<version>` and
then recorded in `metadata/packages-v1.json`.

Separate roots make the database authoritative, permit exact uninstall, avoid
deleting shared namespace directories, and allow rollback without merging
partially installed trees into `site-packages`. Each committed root is inserted
into the controlled `sys.path`.

Project names use PEP 503 normalization. The runtime-managed `packaging`
distribution evaluates PEP 440 specifiers, PEP 508 requirements, and markers.
yt-dlp and packaging are protected core packages installed through the same
transaction engine as user packages; neither is bundled with the library.

Downloaded wheel members ending in `.so`, `.dylib`, `.bundle`, `.pyd`, or
`.dll`, and non-pure wheel metadata, trigger native compatibility checks. With
the default `bundledOnly` policy, installation succeeds only when
`native-packages.json` matches distribution version and `cp314`; downloaded
binaries are then omitted during extraction. The current manifest intentionally
declares no native packages, so Brotli, pycryptodomex, CFFI, cryptography, and
native packages report unavailable unless their signed framework artifacts are staged.

GitHub is recognized as the only permitted Git host by default, but source
archive builds currently return `unsupportedBuildBackend`: an in-process,
subprocess-free PEP 517 backend is required before Git installs can be safely
enabled on iOS.
