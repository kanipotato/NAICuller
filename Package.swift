// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NAICuller",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // DB(SQLite3直叩き)・ExifTool連携・スキャン差分判定・サムネイル生成・エクスポートなど、
        // SwiftUI/AppKitに依存しない純粋なロジックをまとめたライブラリ。
        // ここに切り出すことで swift test がGUIなしで高速・安定に走る（既存アプリ群と同じ流儀）。
        // SQLiteはGRDB/SQLite.swift等の外部依存を追加せず、システム標準のlibsqlite3を
        // `import SQLite3`で直接使う（Package.swiftへの追加設定は不要）。
        .target(
            name: "NAICullerCore",
            path: "Sources/NAICullerCore"
        ),
        // 実行ファイル本体。SwiftUIをベースに、性能が必要なサムネイルグリッドだけ
        // NSViewRepresentableでNSCollectionViewを包む。
        .executableTarget(
            name: "NAICuller",
            dependencies: ["NAICullerCore"],
            path: "Sources/NAICuller"
        ),
        // ExifToolServiceTestsは実際にサブプロセスとしてexiftoolを起動する結合テストのため、
        // テスト用リソース（NovelAI生成PNGの実ファイル2〜3枚）をFixtures/に同梱する。
        .testTarget(
            name: "NAICullerCoreTests",
            dependencies: ["NAICullerCore"],
            path: "Tests/NAICullerCoreTests",
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
