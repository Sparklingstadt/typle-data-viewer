// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TypleDataViewer",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
    ],
    targets: [
        .executableTarget(
            name: "TypleDataViewer",
            dependencies: [
                .product(name: "PostgresNIO", package: "postgres-nio"),
            ]
        )
    ]
)
