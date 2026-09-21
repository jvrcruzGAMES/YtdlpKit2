# Plugin management

Python distributions and yt-dlp plugins are separate inventories. A package is
an installed distribution; a plugin is executable Python code that yt-dlp has
loaded and that contributes a capability. `yt-dlp-ejs` is a managed runtime
component but is not itself reported as an extractor or postprocessor plugin.

```swift
try await YtdlpKit.shared.prepare()

for plugin in try await YtdlpKit.shared.plugins.installedPlugins() {
    print(plugin.displayName, plugin.health)
    for capability in plugin.capabilities { print(capability) }
}

let plugin = try await YtdlpKit.shared.plugins.install(.pypi("some-plugin"))
try await YtdlpKit.shared.plugins.uninstall(plugin)
```

Installation delegates to `YtdlpPackageManager`, so its source, hash, and
native-binary policies also apply to plugins. A package that contributes no
loaded yt-dlp capability produces `packageContainsNoPlugin`. Git requirements
remain unavailable until the package manager has a safe subprocess-free PEP
517 implementation.

The scanner reads yt-dlp's live extractor, postprocessor, and JavaScript
challenge-provider registries. It supports the shared namespace directories
`yt_dlp_plugins.extractor` and `yt_dlp_plugins.postprocessor`, associates files
with distributions through `importlib.metadata`, and preserves import errors.
`refresh()` invalidates import caches and rebuilds the registries. Python cannot
reliably unload every object already retained by callers, so applications
should discard old descriptors after refreshing.

`yt-dlp-apple-webkit-jsi` 0.1.1 is installed from its released pure-Python
wheel and protected from normal removal. Preparation succeeds only after the
plugin has registered an available `apple-webkit-jsi` provider. Its Python code
uses Apple WebKit dynamically; YtdlpKit2 links WebKit, CoreFoundation, and
CoreGraphics so those native frameworks are present and signed with the app.
No Node, Deno, or Bun executable is bundled or downloaded.

## Security

A yt-dlp plugin is executable Python code and runs in the application process
with the same Python and app permissions as YtdlpKit2. Additional plugin paths
configured through `additionalPluginDirectories` must therefore be trusted.

## Native Python dependencies

BeeWare Python Apple Support remains appropriate for the embedded CPython
runtime. BeeWare Mobile Forge is semi-retired, has no Python 3.14 plan, and is
not used for new extension builds. Native Python wheels should instead be
cross-built and tested for Apple targets with cibuildwheel, converted into
signed bundle artifacts, registered in `native-packages.json`, and never
downloaded as executable code at runtime. The currently required plugin stack
does not add a compiled Python extension.
