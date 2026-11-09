// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "blacktext",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "BlackTextCore", targets: ["BlackTextCore"]),
        .executable(name: "BlackTextApp", targets: ["BlackTextApp"]),
        .executable(name: "blacktext", targets: ["blacktext"]),
        .executable(name: "blacktext-bench", targets: ["blacktext-bench"]),
    ],
    dependencies: [
        // In-app updates for the Mac app downloaded from the website. Pinned: updates are signed and
        // installed by this code, so a new version comes in only on purpose.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .target(
            name: "BlackTextCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "BlackTextApp",
            dependencies: ["BlackTextCore", .product(name: "Sparkle", package: "Sparkle")]
        ),
        .executableTarget(
            name: "blacktext",
            dependencies: ["BlackTextCore"]
        ),
        .executableTarget(
            name: "blacktext-bench",
            dependencies: ["BlackTextCore"]
        ),
        .testTarget(
            name: "BlackTextCoreTests",
            dependencies: ["BlackTextCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
