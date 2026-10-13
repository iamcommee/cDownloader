// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "cDownloader",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "cDownloaderCore", targets: ["cDownloaderCore"]),
        .executable(name: "cDownloader", targets: ["cDownloader"]),
        .executable(name: "cDownloaderHost", targets: ["cDownloaderHost"]),
        .executable(name: "cdownloader-cli", targets: ["cDownloaderCLI"]),
    ],
    targets: [
        .target(
            name: "cDownloaderCore",
            linkerSettings: [.linkedFramework("Network"), .linkedFramework("Security")]
        ),
        .executableTarget(
            name: "cDownloader",
            dependencies: ["cDownloaderCore"]
        ),
        .executableTarget(
            name: "cDownloaderHost",
            dependencies: ["cDownloaderCore"]
        ),
        .executableTarget(
            name: "cDownloaderCLI",
            dependencies: ["cDownloaderCore"]
        ),
        .testTarget(
            name: "cDownloaderCoreTests",
            dependencies: ["cDownloaderCore"]
        ),
    ]
)
