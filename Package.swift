// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WaveGenFS",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "WaveGenFS", targets: ["WaveGenFS"])
    ],
    targets: [
        .executableTarget(
            name: "WaveGenFS",
            path: "Sources/WaveGenFS",
            swiftSettings: [.unsafeFlags(["-Ounchecked"])]
        )
    ]
)
