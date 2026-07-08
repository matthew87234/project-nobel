// swift-tools-version: 6.3
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
        ),
        .testTarget(
            name: "macOS-NativeTests",
            dependencies: ["macOS-Native"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
