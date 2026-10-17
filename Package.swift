// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DroidDrop",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "DroidDrop", path: "Sources/DroidDrop")
    ]
)
