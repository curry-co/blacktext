// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "blacktext",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BlackTextApp", targets: ["BlackTextApp"]),
        .executable(name: "blacktext", targets: ["blacktext"]),
        .executable(name: "blacktext-bench", targets: ["blacktext-bench"]),
    ],
    targets: [
        .target(
            name: "BlackTextCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "BlackTextApp",
            dependencies: ["BlackTextCore"]
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
