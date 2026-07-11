// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OuraProtocol",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "OuraProtocol",
            targets: ["OuraProtocol"]
        ),
        .executable(
            name: "oura-decode",
            targets: ["oura-decode"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "OuraProtocol",
            dependencies: [],
            path: "Sources/OuraProtocol",
            linkerSettings: [
                .linkedFramework("CommonCrypto", .when(platforms: [.iOS, .macOS])),
            ]
        ),
        .testTarget(
            name: "OuraProtocolTests",
            dependencies: ["OuraProtocol"],
            path: "Tests"
        ),
        .executableTarget(
            name: "oura-decode",
            dependencies: ["OuraProtocol"],
            path: "Sources/oura-decode"
        ),
    ]
)
