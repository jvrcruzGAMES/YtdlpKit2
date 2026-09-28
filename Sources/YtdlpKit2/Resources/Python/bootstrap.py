"""Bootstrap and diagnostics for the embedded YtdlpKit2 interpreter."""

import os
import platform
import sys
import native_frameworks

native_frameworks.install()


def runtime_info():
    return {
        "python_version": platform.python_version(),
        "implementation": platform.python_implementation(),
        "platform": platform.platform(),
        "sys_platform": sys.platform,
        "machine": platform.machine(),
        "sys_path": list(sys.path),
    }


def validate_environment():
    if sys.implementation.name != "cpython":
        raise RuntimeError("YtdlpKit2 requires CPython")
    return True


def configure_certificate_authorities():
    """Configure OpenSSL and Python HTTP clients to use certifi on Apple OSes."""
    import certifi

    bundle = os.path.realpath(certifi.where())
    if not os.path.isfile(bundle):
        raise RuntimeError(f"certifi CA bundle is missing: {bundle}")
    for variable in ("SSL_CERT_FILE", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE"):
        os.environ[variable] = bundle

    # Fail preparation immediately if the file cannot initialize an SSL trust
    # context instead of surfacing a vague verification error during download.
    import ssl
    context = ssl.create_default_context(cafile=bundle)
    if context.cert_store_stats().get("x509_ca", 0) == 0:
        raise RuntimeError("certifi CA bundle contains no trusted authorities")
    return bundle


def bridge_test(value):
    return value * 2


def validate_brotli():
    import brotli

    payload = b"YtdlpKit2 native Brotli self-test" * 4
    return brotli.decompress(brotli.compress(payload)) == payload


def validate_native_packages():
    import _cffi_backend
    native_frameworks.load_extension("cryptography.hazmat.bindings._rust")
    curl_wrapper = native_frameworks.load_extension("curl_cffi._wrapper")

    from Cryptodome.Cipher import AES
    key = b"YtdlpKit2-key-16"
    plaintext = b"native-test-data"
    encrypted = AES.new(key, AES.MODE_ECB).encrypt(plaintext)
    if AES.new(key, AES.MODE_ECB).decrypt(encrypted) != plaintext:
        return False
    return (hasattr(_cffi_backend, "FFI")
            and hasattr(curl_wrapper, "lib"))
