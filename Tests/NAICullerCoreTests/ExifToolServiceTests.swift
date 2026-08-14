import XCTest
@testable import NAICullerCore

/// 実際にexiftoolをサブプロセスとして起動する結合テスト。
/// `~/Dev/work/novelAI/tmp/`から実データ検証済みのNovelAI生成PNGをコピーした
/// テスト固定資産（Fixtures/sample1.png 等）を使う。
/// 実データ検証で確認済みの前提（詳細設計・冒頭のExifTool実データ検証結果）：
/// - PNG:Descriptionにプロンプト本文がプレーンテキストで入っている
/// - PNG:SoftwareがNovelAI
/// このテストではその前提が実際に成り立つこと、およびタグ書き込み（XMP:Subject）の
/// 読み書きが正しく動くことを検証する。
final class ExifToolServiceTests: XCTestCase {
    private var service: ExifToolService!
    private var workDir: URL!

    override func setUpWithError() throws {
        guard let executableURL = ExifToolService.locateExecutable() else {
            throw XCTSkip("exiftoolが見つからないためスキップ（brew install exiftoolが必要）")
        }
        service = try ExifToolService(executableURL: executableURL)

        // Fixturesの実ファイルを書き込みテストで汚さないよう、一時ディレクトリへコピーして使う。
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        for name in ["sample1.png", "sample2.png", "sample3.png"] {
            guard let fixtureURL = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
                continue
            }
            try FileManager.default.copyItem(at: fixtureURL, to: workDir.appendingPathComponent(name))
        }
    }

    override func tearDownWithError() throws {
        service?.close()
        service = nil
        if let workDir {
            try? FileManager.default.removeItem(at: workDir)
        }
    }

    private func copiedFixturePath(_ name: String) -> String {
        workDir.appendingPathComponent(name).path
    }

    func testLocateExecutableFindsInstalledBinary() {
        let url = ExifToolService.locateExecutable()
        XCTAssertNotNil(url, "brew install exiftool 済みの前提のため見つかるはず")
    }

    /// 実データ検証結果の裏付け：PNG:DescriptionにNovelAIのプロンプト本文がそのまま入っている。
    func testReadMetadataExtractsPromptFromDescription() throws {
        let metadata = try service.readMetadata(path: copiedFixturePath("sample1.png"))
        XCTAssertEqual(metadata.software, "NovelAI")
        XCTAssertNotNil(metadata.promptDescription)
        XCTAssertFalse(metadata.promptDescription!.isEmpty)
        // NovelAI生成画像のプロンプトは一貫して "1girl, chibi" を含む（このFixture群の特徴）。
        XCTAssertTrue(metadata.promptDescription!.contains("1girl"))
    }

    func testReadMetadataReturnsImageDimensions() throws {
        let metadata = try service.readMetadata(path: copiedFixturePath("sample1.png"))
        XCTAssertNotNil(metadata.width)
        XCTAssertNotNil(metadata.height)
        XCTAssertGreaterThan(metadata.width ?? 0, 0)
        XCTAssertGreaterThan(metadata.height ?? 0, 0)
    }

    func testReadMetadataReturnsEmptyTagsBeforeAnyWrite() throws {
        let metadata = try service.readMetadata(path: copiedFixturePath("sample2.png"))
        XCTAssertEqual(metadata.tagNames, [])
    }

    /// タグ追加→読み取り→削除→読み取りのラウンドトリップ。単一値・複数値どちらも正規化して
    /// 配列で返せることを検証する（実データ検証で確認済み：単一値は文字列、複数値は配列で返る）。
    func testAddAndRemoveTagRoundTrip() throws {
        let path = copiedFixturePath("sample1.png")

        try service.addTag("お気に入り", to: path)
        var metadata = try service.readMetadata(path: path)
        XCTAssertEqual(metadata.tagNames, ["お気に入り"])

        try service.addTag("用途:blog", to: path)
        metadata = try service.readMetadata(path: path)
        XCTAssertEqual(Set(metadata.tagNames), ["お気に入り", "用途:blog"])

        try service.removeTag("お気に入り", from: path)
        metadata = try service.readMetadata(path: path)
        XCTAssertEqual(metadata.tagNames, ["用途:blog"])
    }

    /// タグの書き込みがPNG:Description/PNG:Commentを破壊しない（別名前空間を使っているため衝突しない）ことを検証する。
    func testWritingTagDoesNotAffectPromptDescription() throws {
        let path = copiedFixturePath("sample3.png")
        let before = try service.readMetadata(path: path)

        try service.addTag("削除対象", to: path)

        let after = try service.readMetadata(path: path)
        XCTAssertEqual(before.promptDescription, after.promptDescription)
        XCTAssertEqual(after.tagNames, ["削除対象"])
    }

    func testReadMetadataThrowsForNonexistentFile() {
        XCTAssertThrowsError(try service.readMetadata(path: "/no/such/file.png"))
    }

    /// 実機で発生した不具合の回帰テスト：`ExifToolProcess.close()`は以前
    /// `Process.waitUntilExit()`をタイムアウト無しで呼んでおり、アプリ終了処理
    /// （メインスレッド）から呼ばれた際にexiftool側が即座に終了しないと無期限に
    /// フリーズしてしまう不具合があった（Quitが効かなくなり強制終了するしかなくなった）。
    /// `close()`が有限時間で返ることを確認する（タイムアウト値2秒に対して十分小さい上限）。
    func testCloseReturnsPromptlyRatherThanBlockingIndefinitely() {
        let start = Date()
        service.close()
        service = nil // tearDownで二重にcloseを呼ばないようにする
        XCTAssertLessThan(Date().timeIntervalSince(start), 5.0, "closeが正常系で長時間ブロックしている")
    }

    /// コードレビュー指摘の回帰テスト：`close()`の`guard isRunning`はクロージャからの脱出
    /// でしかなく、以前は閉じ済みでも待機処理まで到達していた。2回目以降のclose()は
    /// 何もせず即座に返ること（shutdown()の後にdeinitが走る経路で余計な待機をしない）。
    func testSecondCloseIsNoOpAndReturnsImmediately() {
        service.close()
        let start = Date()
        service.close() // 2回目
        service.close() // 3回目
        service = nil
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, "閉じ済みのcloseが待機している")
    }

    /// 書き込み権限のないディレクトリ配下のファイルへのタグ付けはエラーになる
    /// （詳細設計 5章：「ExifTool書き込み失敗 → トースト通知、DBのタグ状態は変更しない」の前提となる動作）。
    /// exiftoolは`-overwrite_original`でも「一時ファイルを同ディレクトリに作ってrenameする」実装のため、
    /// ファイル自体をread-onlyにしただけでは失敗を再現できない（ディレクトリの書き込み権限で決まる）。
    /// 実データで検証済み：ディレクトリを555にすると一時ファイル作成に失敗しエラーになる。
    func testAddTagFailsWhenDirectoryIsNotWritable() throws {
        let readOnlyDir = workDir.appendingPathComponent("readonly-dir")
        try FileManager.default.createDirectory(at: readOnlyDir, withIntermediateDirectories: true)
        let path = readOnlyDir.appendingPathComponent("target.png")
        try FileManager.default.copyItem(
            at: workDir.appendingPathComponent("sample2.png"),
            to: path
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnlyDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnlyDir.path) }

        XCTAssertThrowsError(try service.addTag("お気に入り", to: path.path))
    }
}
