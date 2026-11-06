// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "macOS-Native",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "macOS-Native",
            path: "Sources/macOS-Native"
        )
    ]
)
