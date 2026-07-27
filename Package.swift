// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "T3Notch",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "T3NotchCore", targets: ["T3NotchCore"]),
        .executable(name: "T3Notch", targets: ["T3Notch"]),
    ],
    targets: [
        .systemLibrary(
            name: "CCommonCrypto",
            path: "Sources/CCommonCrypto"
        ),
        .target(
            name: "T3NotchCore",
            dependencies: ["CCommonCrypto"],
            path: "Sources/T3NotchCore"
        ),
        .executableTarget(
            name: "T3Notch",
            dependencies: ["T3NotchCore"],
            path: "Sources/T3Notch"
        ),
        .testTarget(
            name: "T3NotchCoreTests",
            dependencies: ["T3NotchCore"],
            path: "Tests/T3NotchCoreTests",
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
