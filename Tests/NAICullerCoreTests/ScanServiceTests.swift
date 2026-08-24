import XCTest
@testable import NAICullerCore

/// 実プロセスを起動しないフェイクExifTool実装。呼び出し回数を記録できるので、
/// 「mtime/file_sizeが変わっていないファイルはExifToolを再読み込みしない」ことを検証できる。
private final class FakeExifTool: ExifMetadataReading {
    private(set) var readPaths: [String] = []
    var metadataForPath: [String: ExifMetadata] = [:]

    var readCallCount: Int { readPaths.count }

    func readMetadata(path: String) throws -> ExifMetadata {
        readPaths.append(path)
        return metadataForPath[path] ?? ExifMetadata(promptDescription: "prompt for \(path)", width: 100, height: 100, software: "NovelAI", tagNames: [])
    }

    func addTag(_ name: String, to path: String) throws {}
    func removeTag(_ name: String, from path: String) throws {}
}

final class ScanServiceTests: XCTestCase {
    private var tempDir: URL!
    private var db: DatabaseService!
    private var imageRepo: ImageRepository!
    private var tagRepo: TagRepository!
    private var fakeExifTool: FakeExifTool!
    private var scanService: ScanService!

    override func setUpWithError() throws {
        let rawTempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: rawTempDir, withIntermediateDirectories: true)
        // macOSの/var(firmlink)と/private/varのエイリアスにより、FileManager.enumerator(at:)が
        // 返すパスは常に/private/var形式(realpath(3)の解決結果)になる。resolvingSymlinksInPath()は
        // firmlinkを解決しないため一致しないことがあり、realpath(3)を直接呼んで揃える。
        tempDir = URL(fileURLWithPath: Self.realpath(rawTempDir.path))
        db = try DatabaseService(path: ":memory:")
        imageRepo = ImageRepository(db: db)
        tagRepo = TagRepository(db: db)
        fakeExifTool = FakeExifTool()
        scanService = ScanService(imageRepository: imageRepo, tagRepository: tagRepo, exifTool: fakeExifTool)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// `realpath(3)`でシンボリックリンク/firmlinkを解決した絶対パスを返す。パスが存在しない場合は
    /// 元の文字列をそのまま返す。
    private static func realpath(_ path: String) -> String {
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard Foundation.realpath(path, &buffer) != nil else { return path }
        return String(cString: buffer)
    }

    @discardableResult
    private func writeDummyPNG(_ name: String, in directory: URL? = nil) throws -> URL {
        let url = (directory ?? tempDir).appendingPathComponent(name)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)
        return url
    }

    func testNewFilesAreScannedAndInserted() throws {
        try writeDummyPNG("a.png")
        try writeDummyPNG("b.png")
        let rootId = try imageRepo.insertRoot(path: tempDir.path)
        let root = try imageRepo.fetchAllRoots().first { $0.id == rootId }!

        let result = try scanService.scan(roots: [root])

        XCTAssertEqual(result.newImageCount, 2)
        XCTAssertEqual(result.updatedImageCount, 0)
        XCTAssertEqual(fakeExifTool.readCallCount, 2)
        XCTAssertEqual(try imageRepo.fetchImages(rootId: rootId).count, 2)
    }

    func testNonPngFilesAreIgnored() throws {
        try writeDummyPNG("a.png")
        let txtURL = tempDir.appendingPathComponent("notes.txt")
        try "memo".data(using: .utf8)!.write(to: txtURL)
        _ = try imageRepo.insertRoot(path: tempDir.path)
        let root = try imageRepo.fetchAllRoots().first!

        let result = try scanService.scan(roots: [root])
        XCTAssertEqual(result.newImageCount, 1)
    }

    /// 受け入れ基準：「2回目以降のスキャンで変更のないファイルの再読み込みが発生しない」。
    func testUnchangedFileIsNotRereadOnSecondScan() throws {
        try writeDummyPNG("a.png")
        _ = try imageRepo.insertRoot(path: tempDir.path)
        let root = try imageRepo.fetchAllRoots().first!

        _ = try scanService.scan(roots: [root])
        XCTAssertEqual(fakeExifTool.readCallCount, 1)

        let secondResult = try scanService.scan(roots: [root])
        XCTAssertEqual(secondResult.newImageCount, 0)
        XCTAssertEqual(secondResult.updatedImageCount, 0)
        XCTAssertEqual(secondResult.unchangedImageCount, 1)
        // ExifToolの呼び出し回数が1回目から増えていない＝再読み込みしていない。
        XCTAssertEqual(fakeExifTool.readCallCount, 1)
    }

    func testModifiedFileIsReReadAndUpdated() throws {
        let fileURL = try writeDummyPNG("a.png")
        _ = try imageRepo.insertRoot(path: tempDir.path)
        let root = try imageRepo.fetchAllRoots().first!
        _ = try scanService.scan(roots: [root])
        XCTAssertEqual(fakeExifTool.readCallCount, 1)

        // ファイル内容とmtimeを変更する。
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x00]).write(to: fileURL)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: fileURL.path)
        fakeExifTool.metadataForPath[fileURL.path] = ExifMetadata(promptDescription: "updated prompt", width: 200, height: 200, software: "NovelAI", tagNames: [])

        let result = try scanService.scan(roots: [root])
        XCTAssertEqual(result.updatedImageCount, 1)
        XCTAssertEqual(fakeExifTool.readCallCount, 2)

        let record = try imageRepo.fetchImage(byPath: fileURL.path)
        XCTAssertEqual(record?.promptCache, "updated prompt")
        XCTAssertEqual(record?.width, 200)
    }

    func testMissingRootIsSkippedWithWarningAndDoesNotOrphanExistingRecords() throws {
        try writeDummyPNG("a.png")
        let rootId = try imageRepo.insertRoot(path: tempDir.path)
        let root = try imageRepo.fetchAllRoots().first!
        _ = try scanService.scan(roots: [root])

        // ルートディレクトリごと消える（外付けドライブ未マウント等を模す）。
        try FileManager.default.removeItem(at: tempDir)

        let result = try scanService.scan(roots: [root])
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertEqual(result.warnings.first?.rootPath, tempDir.path)
        // ルート自体が消えている場合は孤児扱いにしない（既存レコードは保持する）。
        XCTAssertTrue(result.orphanImages.isEmpty)
        XCTAssertEqual(try imageRepo.fetchImages(rootId: rootId).count, 1)
    }

    /// 受け入れ基準：孤児レコード検出。ファイルだけが消えたケース（ルート自体は健在）。
    func testOrphanDetectionWhenFileIsDeletedButRootRemains() throws {
        let fileURL = try writeDummyPNG("a.png")
        try writeDummyPNG("b.png")
        let rootId = try imageRepo.insertRoot(path: tempDir.path)
        let root = try imageRepo.fetchAllRoots().first!
        _ = try scanService.scan(roots: [root])

        try FileManager.default.removeItem(at: fileURL)

        let result = try scanService.scan(roots: [root])
        XCTAssertEqual(result.orphanImages.count, 1)
        XCTAssertEqual(result.orphanImages.first?.path, fileURL.path)
        // 自動削除はしない：DBにはまだ残っている。
        XCTAssertEqual(try imageRepo.fetchImages(rootId: rootId).count, 2)

        // ユーザーが確認した後の削除はImageRepository.deleteImagesで行う。
        try imageRepo.deleteImages(ids: result.orphanImages.map(\.id))
        XCTAssertEqual(try imageRepo.fetchImages(rootId: rootId).count, 1)
    }

    /// 受け入れ基準：DBファイルを削除した状態で再スキャンしても画像ファイル側のメタデータから
    /// タグが正しく復元される、を模したテスト。XMP:Subjectに相当する`tagNames`をフェイクが返し、
    /// ScanServiceがそれを見てtags/image_tagsを再構築できることを検証する。
    func testTagsAreRestoredFromFileMetadataOnScan() throws {
        let fileURL = try writeDummyPNG("a.png")
        fakeExifTool.metadataForPath[fileURL.path] = ExifMetadata(
            promptDescription: "prompt",
            width: 100,
            height: 100,
            software: "NovelAI",
            tagNames: ["お気に入り", "用途:blog"]
        )
        _ = try imageRepo.insertRoot(path: tempDir.path)
        let root = try imageRepo.fetchAllRoots().first!

        _ = try scanService.scan(roots: [root])

        let record = try imageRepo.fetchImage(byPath: fileURL.path)!
        let tags = try tagRepo.tags(forImage: record.id)
        let tagNames = Set(tags.map(\.name))
        XCTAssertEqual(tagNames, ["お気に入り", "用途:blog"])
        // "お気に入り"は固定タグ（is_system）に正しく紐付いており、新規重複作成されていないこと。
        XCTAssertTrue(tags.contains { $0.name == "お気に入り" && $0.isSystem })
    }

    /// Stable Diffusion(ComfyUI)対応：スキャン時に生成元プラットフォームが判定・保存されること。
    func testSourcePlatformIsDetectedAndPersistedDuringScan() throws {
        let naiURL = try writeDummyPNG("nai.png")
        let comfyURL = try writeDummyPNG("comfy.png")
        let unknownURL = try writeDummyPNG("unknown.png")

        fakeExifTool.metadataForPath[naiURL.path] = ExifMetadata(
            promptDescription: "1girl, chibi", width: 100, height: 100, software: "NovelAI",
            naiCommentJSON: #"{"seed": 999, "steps": 28}"#, tagNames: []
        )
        fakeExifTool.metadataForPath[comfyURL.path] = ExifMetadata(
            promptDescription: nil, width: 100, height: 100, software: nil,
            comfyPromptJSON: #"{"CheckpointLoaderSimple.0": {"class_type": "CheckpointLoaderSimple", "inputs": {}}}"#,
            tagNames: []
        )
        fakeExifTool.metadataForPath[unknownURL.path] = ExifMetadata(
            promptDescription: nil, width: 100, height: 100, software: nil, tagNames: []
        )

        _ = try imageRepo.insertRoot(path: tempDir.path)
        let root = try imageRepo.fetchAllRoots().first!
        _ = try scanService.scan(roots: [root])

        XCTAssertEqual(try imageRepo.fetchImage(byPath: naiURL.path)?.sourcePlatform, .novelAI)
        XCTAssertEqual(try imageRepo.fetchImage(byPath: naiURL.path)?.naiGenerationInfoJSON, #"{"seed": 999, "steps": 28}"#)
        XCTAssertEqual(try imageRepo.fetchImage(byPath: comfyURL.path)?.sourcePlatform, .comfyUI)
        XCTAssertNotNil(try imageRepo.fetchImage(byPath: comfyURL.path)?.comfyGenerationInfoJSON)
        XCTAssertEqual(try imageRepo.fetchImage(byPath: unknownURL.path)?.sourcePlatform, .unknown)
    }

    func testTagsRemovedFromFileAreUnsyncedOnUpdate() throws {
        let fileURL = try writeDummyPNG("a.png")
        fakeExifTool.metadataForPath[fileURL.path] = ExifMetadata(
            promptDescription: "prompt", width: 100, height: 100, software: "NovelAI", tagNames: ["お気に入り"]
        )
        _ = try imageRepo.insertRoot(path: tempDir.path)
        let root = try imageRepo.fetchAllRoots().first!
        _ = try scanService.scan(roots: [root])

        // ファイル側からタグが消え、mtimeも更新された状態を模す。
        fakeExifTool.metadataForPath[fileURL.path] = ExifMetadata(
            promptDescription: "prompt", width: 100, height: 100, software: "NovelAI", tagNames: []
        )
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: fileURL.path)

        _ = try scanService.scan(roots: [root])

        let record = try imageRepo.fetchImage(byPath: fileURL.path)!
        XCTAssertTrue(try tagRepo.tags(forImage: record.id).isEmpty)
    }
}
