// swift-tools-version: 6.0
import PackageDescription

// 単体の実行ファイルでもバンドル ID を持てるよう、Info.plist をバイナリの __TEXT,__info_plist に埋め込む。
// Xcode はリンカをパッケージ外のディレクトリから呼ぶことがあるので、絶対パスで渡す
let infoPlistPath = Context.packageDirectory + "/Supporting/Info.plist"

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
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", infoPlistPath,
                ])
            ]
        )
    ]
)
