// swift-tools-version: 6.0
// Tools version 6.0 = Swift 6 language mode (strict concurrency checking) by default.
import PackageDescription

let package = Package(
    name: "LinkLensProbe",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "linklens-probe", targets: ["linklens-probe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        // All the logic lives in this library so that tests can import it.
        .target(name: "ProbeCore"),
        // Thin command-line layer: parses arguments and calls ProbeCore.
        .executableTarget(
            name: "linklens-probe",
            dependencies: [
                "ProbeCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "ProbeCoreTests", dependencies: ["ProbeCore"]),
    ]
)
