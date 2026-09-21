# CPython artifact staging

`Python.xcframework` is generated here by `Scripts/build-python.sh` from the
SHA-256-pinned BeeWare Python Apple Support release described in
`Scripts/cpython-distribution.json`. This distribution uses upstream CPython:
the macOS slice repackages python.org's official binary and the iOS slice uses
CPython's official PEP 730 implementation. The package currently stages only
these macOS and iOS distributions.
It is intentionally not represented by a placeholder binary. When present,
`Package.swift` automatically adds it as the `YtdlpKit2CPython` binary target.
