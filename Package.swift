// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TypleDataViewer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "TypleDataViewer")
    ]
)
