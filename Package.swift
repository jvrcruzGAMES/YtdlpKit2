// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Release packaging stages this generated artifact before manifest resolution.
let bundledRuntime = "Native/CPython/Python.xcframework"
let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let hasBundledRuntime = FileManager.default.fileExists(
    atPath: packageDirectory.appendingPathComponent(bundledRuntime + "/Info.plist").path
)
let bundledBrotli = "Native/Brotli/_brotli.xcframework"
let hasBundledBrotli = FileManager.default.fileExists(
    atPath: packageDirectory.appendingPathComponent(bundledBrotli + "/Info.plist").path
)
var nativeDependencies: [Target.Dependency] = []
var nativeCSettings: [CSetting] = []
if hasBundledBrotli {
    nativeDependencies.append("YtdlpKit2Brotli")
    nativeCSettings.append(.define("YTDLPKIT_HAS_BROTLI"))
}
var ytdlpDependencies: [Target.Dependency] = [
    "YtdlpKit2Native",
    .product(name: "PythonKit", package: "PythonKit"),
]
if hasBundledRuntime { ytdlpDependencies.append("YtdlpKit2CPython") }
let extensionDirectory = packageDirectory.appendingPathComponent("Native/PythonExtensions")
let bundledExtensions = ((try? FileManager.default.contentsOfDirectory(
    at: extensionDirectory, includingPropertiesForKeys: nil
)) ?? []).filter { $0.pathExtension == "xcframework" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
let extensionTargets: [(name: String, path: String)] = bundledExtensions.enumerated().map { index, url in
    ("YtdlpKit2PyExt\(index)", "Native/PythonExtensions/\(url.lastPathComponent)")
}
let stdlibExtensionDirectory = packageDirectory.appendingPathComponent("Native/PythonStdlibExtensions")
let discoveredStdlibExtensions = ((try? FileManager.default.contentsOfDirectory(
    at: stdlibExtensionDirectory, includingPropertiesForKeys: nil
)) ?? []).filter { $0.pathExtension == "xcframework" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
let knownStdlibExtensionNames = [
    "_asyncio", "_bisect", "_blake2", "_bz2", "_codecs_cn", "_codecs_hk",
    "_codecs_iso2022", "_codecs_jp", "_codecs_kr", "_codecs_tw", "_csv",
    "_ctypes", "_dbm", "_decimal", "_elementtree", "_hashlib", "_heapq",
    "_hmac", "_interpchannels", "_interpqueues", "_interpreters", "_json",
    "_lsprof", "_lzma", "_md5", "_multibytecodec", "_pickle", "_queue",
    "_random", "_remote_debugging", "_sha1", "_sha2", "_sha3", "_socket",
    "_sqlite3", "_ssl", "_statistics", "_struct", "_uuid", "_zoneinfo",
    "_zstd", "array", "binascii", "cmath", "fcntl", "math", "mmap",
    "pyexpat", "resource", "select", "termios", "unicodedata", "zlib",
]
let bundledStdlibExtensions = discoveredStdlibExtensions.isEmpty
    ? knownStdlibExtensionNames.map { stdlibExtensionDirectory.appendingPathComponent("\($0).xcframework") }
    : discoveredStdlibExtensions
let stdlibExtensionTargets: [(name: String, path: String)] = bundledStdlibExtensions.enumerated().map { index, url in
    ("YtdlpKit2PyStdlib\(index)", "Native/PythonStdlibExtensions/\(url.lastPathComponent)")
}
// Presence is evaluated when release tooling stages the pinned artifacts.
let ffmpegLibraries = ["ffmpegkit", "libavcodec", "libavdevice", "libavfilter", "libavformat", "libavutil", "libswresample", "libswscale"]
let hasFFmpegKitNext = ffmpegLibraries.allSatisfy {
    FileManager.default.fileExists(atPath: packageDirectory
        .appendingPathComponent("Native/FFmpegKitNext/\($0).xcframework/Info.plist").path)
}
if hasFFmpegKitNext {
    ytdlpDependencies.append(contentsOf: ffmpegLibraries.map { .target(name: "YtdlpKit2FFmpeg_\($0)") })
}
ytdlpDependencies.append(contentsOf: extensionTargets.map {
    .target(name: $0.name, condition: .when(platforms: [.iOS]))
})
ytdlpDependencies.append(contentsOf: stdlibExtensionTargets.map {
    .target(name: $0.name, condition: .when(platforms: [.iOS]))
})

var packageTargets: [Target] = [
    .target(name: "YtdlpKit2Native", dependencies: nativeDependencies,
            publicHeadersPath: "include", cSettings: nativeCSettings),
    .target(
        name: "YtdlpKit2",
        dependencies: ytdlpDependencies,
        resources: [
            .copy("Resources/Python"),
            .copy("Resources/Runtime"),
            .process("Resources/runtime-manifest.json"),
            .process("Resources/native-packages.json"),
            .process("Resources/runtime-dependencies.json"),
            .process("Resources/compatibility-lock.json"),
            .process("Resources/ffmpeg-native-manifest.json"),
        ],
        linkerSettings: [
            .linkedFramework("Foundation"),
            .linkedFramework("WebKit"),
            .linkedFramework("CoreFoundation"),
            .linkedFramework("CoreGraphics"),
        ]
    ),
    .testTarget(name: "YtdlpKit2Tests", dependencies: ["YtdlpKit2"]),
]
if hasBundledRuntime {
    packageTargets.append(.binaryTarget(name: "YtdlpKit2CPython", path: bundledRuntime))
}
if hasBundledBrotli {
    packageTargets.append(.binaryTarget(name: "YtdlpKit2Brotli", path: bundledBrotli))
}
packageTargets.append(contentsOf: extensionTargets.map {
    .binaryTarget(name: $0.name, path: $0.path)
})
packageTargets.append(contentsOf: stdlibExtensionTargets.map {
    .binaryTarget(name: $0.name, path: $0.path)
})
if hasFFmpegKitNext {
    packageTargets.append(contentsOf: ffmpegLibraries.map {
        .binaryTarget(name: "YtdlpKit2FFmpeg_\($0)", path: "Native/FFmpegKitNext/\($0).xcframework")
    })
}

let package = Package(
    name: "YtdlpKit2",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "YtdlpKit2", targets: ["YtdlpKit2"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pvieito/PythonKit.git", exact: "1.0.0"),
    ],
    targets: packageTargets
)
