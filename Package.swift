// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ProjectNobel",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "ProjectNobel",
            path: "Sources"
        )
    ]
)
