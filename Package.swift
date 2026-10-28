// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "blktxt",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BlktxtApp", targets: ["BlktxtApp"]),
        .executable(name: "blktxt", targets: ["blktxt"]),
        .executable(name: "blktxt-bench", targets: ["blktxt-bench"]),
    ],
    targets: [
        .target(
            name: "BlktxtCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "BlktxtApp",
            dependencies: ["BlktxtCore"]
        ),
        .executableTarget(
            name: "blktxt",
            dependencies: ["BlktxtCore"]
        ),
        .executableTarget(
            name: "blktxt-bench",
            dependencies: ["BlktxtCore"]
        ),
        .testTarget(
            name: "BlktxtCoreTests",
            dependencies: ["BlktxtCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
