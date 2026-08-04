// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TSVee",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "TSVee",
            path: "Sources/TSVee"
        ),
        .testTarget(
            name: "TSVeeTests",
            dependencies: ["TSVee"],
            path: "Tests/TSVeeTests"
        ),
    ]
)
