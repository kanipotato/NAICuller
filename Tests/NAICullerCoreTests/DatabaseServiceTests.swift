import XCTest
@testable import NAICullerCore

final class DatabaseServiceTests: XCTestCase {
    func testMigrationCreatesSchemaAndSystemTags() throws {
        let db = try DatabaseService(path: ":memory:")
        let tagRepo = TagRepository(db: db)

        let tags = try tagRepo.fetchAll()
        let names = Set(tags.map(\.name))
        XCTAssertTrue(names.contains(Tag.SystemTagName.favorite))
        XCTAssertTrue(names.contains(Tag.SystemTagName.deletionMark))

        let favorite = try tagRepo.fetchByKeyBinding("F")
        XCTAssertEqual(favorite?.name, Tag.SystemTagName.favorite)
        XCTAssertEqual(favorite?.isSystem, true)

        let deletion = try tagRepo.fetchByKeyBinding("G")
        XCTAssertEqual(deletion?.name, Tag.SystemTagName.deletionMark)
    }

    func testImageInsertAndFetchRoundTrip() throws {
        let db = try DatabaseService(path: ":memory:")
        let imageRepo = ImageRepository(db: db)

        let rootId = try imageRepo.insertRoot(path: "/tmp/root1")
        let imageId = try imageRepo.insertImage(
            rootId: rootId,
            path: "/tmp/root1/a.png",
            mtime: 1000.5,
            fileSize: 12345,
            width: 832,
            height: 1216,
            promptCache: "1girl, chibi"
        )

        let fetched = try imageRepo.fetchImage(byPath: "/tmp/root1/a.png")
        XCTAssertEqual(fetched?.id, imageId)
        XCTAssertEqual(fetched?.rootId, rootId)
        XCTAssertEqual(fetched?.mtime, 1000.5)
        XCTAssertEqual(fetched?.fileSize, 12345)
        XCTAssertEqual(fetched?.width, 832)
        XCTAssertEqual(fetched?.height, 1216)
        XCTAssertEqual(fetched?.promptCache, "1girl, chibi")
        // 明示的に指定しない場合は.unknown（旧スキーマ由来・未スキャンと同じ扱い）。
        XCTAssertEqual(fetched?.sourcePlatform, .unknown)
        XCTAssertNil(fetched?.comfyGenerationInfoJSON)
    }

    /// Stable Diffusion(ComfyUI)対応で追加した2カラム（source_platform/comfy_prompt_json）の
    /// 挿入・更新・読み取りラウンドトリップ。
    func testSourcePlatformAndComfyPromptJSONRoundTrip() throws {
        let db = try DatabaseService(path: ":memory:")
        let imageRepo = ImageRepository(db: db)
        let rootId = try imageRepo.insertRoot(path: "/tmp/root1")

        let imageId = try imageRepo.insertImage(
            rootId: rootId,
            path: "/tmp/root1/a.png",
            mtime: 1,
            fileSize: 1,
            width: nil,
            height: nil,
            promptCache: nil,
            sourcePlatform: .comfyUI,
            comfyGenerationInfoJSON: #"{"CheckpointLoaderSimple.0": {"class_type": "CheckpointLoaderSimple", "inputs": {}}}"#
        )

        var fetched = try imageRepo.fetchImage(byPath: "/tmp/root1/a.png")
        XCTAssertEqual(fetched?.sourcePlatform, .comfyUI)
        XCTAssertEqual(fetched?.comfyGenerationInfoJSON, #"{"CheckpointLoaderSimple.0": {"class_type": "CheckpointLoaderSimple", "inputs": {}}}"#)

        // updateImageでも正しく上書きされること（再スキャンでの更新経路）。
        try imageRepo.updateImage(
            id: imageId,
            mtime: 2,
            fileSize: 2,
            width: nil,
            height: nil,
            promptCache: nil,
            sourcePlatform: .novelAI,
            comfyGenerationInfoJSON: nil
        )
        fetched = try imageRepo.fetchImage(byPath: "/tmp/root1/a.png")
        XCTAssertEqual(fetched?.sourcePlatform, .novelAI)
        XCTAssertNil(fetched?.comfyGenerationInfoJSON)
    }

    /// NovelAI画像のseed対応で追加した`nai_comment_json`カラムのラウンドトリップ。
    func testNaiCommentJSONRoundTrip() throws {
        let db = try DatabaseService(path: ":memory:")
        let imageRepo = ImageRepository(db: db)
        let rootId = try imageRepo.insertRoot(path: "/tmp/root1")

        _ = try imageRepo.insertImage(
            rootId: rootId,
            path: "/tmp/root1/a.png",
            mtime: 1,
            fileSize: 1,
            width: nil,
            height: nil,
            promptCache: "1girl, chibi",
            sourcePlatform: .novelAI,
            naiGenerationInfoJSON: #"{"seed": 123, "steps": 28}"#
        )

        let fetched = try imageRepo.fetchImage(byPath: "/tmp/root1/a.png")
        XCTAssertEqual(fetched?.naiGenerationInfoJSON, #"{"seed": 123, "steps": 28}"#)
    }

    func testImagePathIsUnique() throws {
        let db = try DatabaseService(path: ":memory:")
        let imageRepo = ImageRepository(db: db)
        let rootId = try imageRepo.insertRoot(path: "/tmp/root1")
        _ = try imageRepo.insertImage(rootId: rootId, path: "/tmp/root1/a.png", mtime: 1, fileSize: 1, width: nil, height: nil, promptCache: nil)

        XCTAssertThrowsError(
            try imageRepo.insertImage(rootId: rootId, path: "/tmp/root1/a.png", mtime: 2, fileSize: 2, width: nil, height: nil, promptCache: nil)
        )
    }

    func testDeletingRootCascadesToImagesAndImageTags() throws {
        let db = try DatabaseService(path: ":memory:")
        let imageRepo = ImageRepository(db: db)
        let tagRepo = TagRepository(db: db)

        let rootId = try imageRepo.insertRoot(path: "/tmp/root1")
        let imageId = try imageRepo.insertImage(rootId: rootId, path: "/tmp/root1/a.png", mtime: 1, fileSize: 1, width: nil, height: nil, promptCache: nil)
        let favorite = try tagRepo.fetchByKeyBinding("F")!
        try tagRepo.addTagToImage(imageId: imageId, tagId: favorite.id)

        try imageRepo.deleteRoot(id: rootId)

        XCTAssertNil(try imageRepo.fetchImage(byPath: "/tmp/root1/a.png"))
        XCTAssertTrue(try tagRepo.imageIds(taggedWith: favorite.id).isEmpty)
    }

    /// key_bindingのUNIQUE制約：同じキーに2つのタグを割り当てようとするとDBレベルで弾かれる
    /// （詳細設計 3章・受け入れ基準：「同じキーに2つのカスタムタグ名を設定しようとすると弾かれる」）。
    func testKeyBindingUniqueConstraint() throws {
        let db = try DatabaseService(path: ":memory:")
        let tagRepo = TagRepository(db: db)

        let tagAId = try tagRepo.insertUserTag(name: "タグA", keyBinding: "1")
        let tagBId = try tagRepo.insertUserTag(name: "タグB")

        // "1"は既にタグAが使っているため、タグBに割り当てようとすると失敗する。
        XCTAssertThrowsError(try tagRepo.setKeyBinding(tagId: tagBId, keyBinding: "1"))

        // 先にタグAの割当を外せば成功する（UI側の「上書き確認」フローに対応する経路）。
        try tagRepo.clearKeyBinding(tagId: tagAId)
        try tagRepo.setKeyBinding(tagId: tagBId, keyBinding: "1")
        XCTAssertEqual(try tagRepo.fetchByKeyBinding("1")?.id, tagBId)
    }

    func testTagNameUniqueConstraint() throws {
        let db = try DatabaseService(path: ":memory:")
        let tagRepo = TagRepository(db: db)
        _ = try tagRepo.insertUserTag(name: "重複タグ")
        XCTAssertThrowsError(try tagRepo.insertUserTag(name: "重複タグ"))
    }

    func testFetchByNameCaseInsensitive() throws {
        let db = try DatabaseService(path: ":memory:")
        let tagRepo = TagRepository(db: db)
        let id = try tagRepo.insertUserTag(name: "Blog")
        let found = try tagRepo.fetchByNameCaseInsensitive("blog")
        XCTAssertEqual(found?.id, id)
    }

    func testAddAndRemoveTagToggle() throws {
        let db = try DatabaseService(path: ":memory:")
        let imageRepo = ImageRepository(db: db)
        let tagRepo = TagRepository(db: db)
        let rootId = try imageRepo.insertRoot(path: "/tmp/root1")
        let imageId = try imageRepo.insertImage(rootId: rootId, path: "/tmp/root1/a.png", mtime: 1, fileSize: 1, width: nil, height: nil, promptCache: nil)
        let favorite = try tagRepo.fetchByKeyBinding("F")!

        XCTAssertTrue(try tagRepo.tagIds(forImage: imageId).isEmpty)
        try tagRepo.addTagToImage(imageId: imageId, tagId: favorite.id)
        XCTAssertEqual(try tagRepo.tagIds(forImage: imageId), [favorite.id])
        try tagRepo.removeTagFromImage(imageId: imageId, tagId: favorite.id)
        XCTAssertTrue(try tagRepo.tagIds(forImage: imageId).isEmpty)
    }

    /// コードレビュー指摘の回帰テスト：`allImageTagIds()`が`tagIds(forImage:)`を画像ごとに
    /// 呼ぶN+1クエリの代わりに、1回のSELECTで全画像分のタグID集合を正しく組み立てられること。
    func testAllImageTagIdsBatchesAcrossImages() throws {
        let db = try DatabaseService(path: ":memory:")
        let imageRepo = ImageRepository(db: db)
        let tagRepo = TagRepository(db: db)
        let rootId = try imageRepo.insertRoot(path: "/tmp/root1")
        let image1 = try imageRepo.insertImage(rootId: rootId, path: "/tmp/root1/a.png", mtime: 1, fileSize: 1, width: nil, height: nil, promptCache: nil)
        let image2 = try imageRepo.insertImage(rootId: rootId, path: "/tmp/root1/b.png", mtime: 1, fileSize: 1, width: nil, height: nil, promptCache: nil)
        let image3 = try imageRepo.insertImage(rootId: rootId, path: "/tmp/root1/c.png", mtime: 1, fileSize: 1, width: nil, height: nil, promptCache: nil)
        let favorite = try tagRepo.fetchByKeyBinding("F")!
        let deletion = try tagRepo.fetchByKeyBinding("G")!

        try tagRepo.addTagToImage(imageId: image1, tagId: favorite.id)
        try tagRepo.addTagToImage(imageId: image1, tagId: deletion.id)
        try tagRepo.addTagToImage(imageId: image2, tagId: deletion.id)
        // image3にはタグを付けない（マッピングにキー自体が存在しないことを確認するため）。

        let mapping = try tagRepo.allImageTagIds()
        XCTAssertEqual(mapping[image1], [favorite.id, deletion.id])
        XCTAssertEqual(mapping[image2], [deletion.id])
        XCTAssertNil(mapping[image3])
    }

    /// レビュー指摘の回帰テスト：`transaction`の中で複数回`run`/`query`を呼んでも
    /// デッドロックしないこと（以前はBEGIN/body/COMMITが別々の`queue.sync`だったため、
    /// 直しかたを誤ると同一スレッドからのネスト`sync`でハングする）。
    /// `ImageRepository.deleteImages`が実際にこのパターン（ループの中で`db.run`）を使っている。
    func testTransactionCommitsMultipleWritesWithoutDeadlock() throws {
        let db = try DatabaseService(path: ":memory:")
        let imageRepo = ImageRepository(db: db)
        let rootId = try imageRepo.insertRoot(path: "/tmp/root1")
        let id1 = try imageRepo.insertImage(rootId: rootId, path: "/tmp/root1/a.png", mtime: 1, fileSize: 1, width: nil, height: nil, promptCache: nil)
        let id2 = try imageRepo.insertImage(rootId: rootId, path: "/tmp/root1/b.png", mtime: 1, fileSize: 1, width: nil, height: nil, promptCache: nil)
        let id3 = try imageRepo.insertImage(rootId: rootId, path: "/tmp/root1/c.png", mtime: 1, fileSize: 1, width: nil, height: nil, promptCache: nil)

        try imageRepo.deleteImages(ids: [id1, id2, id3])

        XCTAssertEqual(try imageRepo.fetchImages(rootId: rootId).count, 0)
    }

    /// トランザクション内で例外が起きたら、途中まで実行された書き込みもロールバックされること。
    func testTransactionRollsBackAllWritesOnError() throws {
        struct Boom: Error {}
        let db = try DatabaseService(path: ":memory:")
        let imageRepo = ImageRepository(db: db)
        let rootId = try imageRepo.insertRoot(path: "/tmp/root1")

        XCTAssertThrowsError(
            try db.transaction {
                try db.run(
                    "INSERT INTO images (root_id, path, mtime, file_size, last_scanned_at) VALUES (?, ?, ?, ?, ?);",
                    [.integer(rootId), .text("/tmp/root1/x.png"), .real(1), .integer(1), .text("now")]
                )
                throw Boom()
            }
        )

        // BEGIN後の書き込みがROLLBACKで消えていること（コミットされて残っていないこと）。
        XCTAssertEqual(try imageRepo.fetchImages(rootId: rootId).count, 0)
    }

    /// 実際に使ってみてのフィードバックの回帰テスト：v1時代からある既存画像
    /// （`source_platform`列が存在しなかった頃のもの）は、列追加だけでは全件`.unknown`のまま
    /// 残ってしまい、通常の「再スキャン」（差分スキャンでmtime/file_size一致ファイルは
    /// ExifTool再読み込みをスキップする）でも直らなかった。ExifToolを叩き直さず、
    /// 既存の`prompt_cache`（v1時代は常にPNG:Descriptionから読んでいた＝NovelAIだけが
    /// 書き込むフィールド）から安全に`.novelai`へバックフィルできることを確認する。
    func testV3MigrationBackfillsNovelAIFromExistingPromptCache() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbPath = tempDir.appendingPathComponent("db.sqlite").path

        let db1 = try DatabaseService(path: dbPath)
        let imageRepo1 = ImageRepository(db: db1)
        let rootId = try imageRepo1.insertRoot(path: "/tmp/root1")
        let novelAIImageId = try imageRepo1.insertImage(
            rootId: rootId, path: "/tmp/root1/a.png", mtime: 1, fileSize: 1,
            width: nil, height: nil, promptCache: "1girl, chibi"
        )
        let noPromptImageId = try imageRepo1.insertImage(
            rootId: rootId, path: "/tmp/root1/b.png", mtime: 1, fileSize: 1,
            width: nil, height: nil, promptCache: nil
        )
        // 「v1時代からある、まだ一度もsource_platform判定されたことがない画像」を再現する：
        // source_platformをNULLに戻し、user_versionを2（source_platform/comfy_prompt_json列は
        // 存在するがバックフィル未実施、nai_comment_json列はまだ無い）に戻す。DatabaseService(path:)
        // は開いた瞬間に最新版まで一気にマイグレーションするため、単にuser_versionだけ戻すと
        // v4のALTER TABLEが「既に存在する列」に対して再実行され失敗する。物理的な列も
        // 実際のv2時点の状態に揃えておく必要がある。
        try db1.execute("UPDATE images SET source_platform = NULL;")
        try db1.execute("ALTER TABLE images DROP COLUMN nai_comment_json;")
        try db1.execute("PRAGMA user_version = 2;")

        // 再オープンでv2→v3への昇格が走り、バックフィルされることを確認する。
        let dbReopened = try DatabaseService(path: dbPath)
        let imageRepoReopened = ImageRepository(db: dbReopened)
        let images = try imageRepoReopened.fetchImages(rootId: rootId)

        XCTAssertEqual(images.first { $0.id == novelAIImageId }?.sourcePlatform, .novelAI)
        // プロンプトが元々読めていなかった画像まで安易にNovelAI扱いしないこと。
        XCTAssertEqual(images.first { $0.id == noPromptImageId }?.sourcePlatform, .unknown)
    }

    func testMigrationIsIdempotentWhenReopeningSamePath() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbPath = tempDir.appendingPathComponent("db.sqlite").path

        let db1 = try DatabaseService(path: dbPath)
        let imageRepo1 = ImageRepository(db: db1)
        _ = try imageRepo1.insertRoot(path: "/tmp/root1")

        // 同じパスを再オープンしても、CREATE TABLEの再実行でエラーにならないこと
        // （PRAGMA user_versionによるマイグレーション管理）。
        let db2 = try DatabaseService(path: dbPath)
        let imageRepo2 = ImageRepository(db: db2)
        XCTAssertEqual(try imageRepo2.fetchAllRoots().count, 1)
    }
}
