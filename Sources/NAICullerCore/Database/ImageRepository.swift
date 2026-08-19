import Foundation

/// `roots`テーブル・`images`テーブルへのアクセスをまとめたリポジトリ。
public final class ImageRepository {
    private let db: DatabaseService

    public init(db: DatabaseService) {
        self.db = db
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // MARK: - roots

    public func fetchAllRoots() throws -> [Root] {
        try db.query("SELECT id, path, added_at FROM roots ORDER BY added_at ASC;") { row in
            Root(id: row.int64(0), path: row.string(1) ?? "", addedAt: Self.isoFormatter.date(from: row.string(2) ?? "") ?? Date(timeIntervalSince1970: 0))
        }
    }

    @discardableResult
    public func insertRoot(path: String, addedAt: Date = Date()) throws -> Int64 {
        try db.run(
            "INSERT INTO roots (path, added_at) VALUES (?, ?);",
            [.text(path), .text(Self.isoFormatter.string(from: addedAt))]
        )
    }

    public func deleteRoot(id: Int64) throws {
        // images/image_tagsはON DELETE CASCADEで連動削除される。
        try db.run("DELETE FROM roots WHERE id = ?;", [.integer(id)])
    }

    // MARK: - images

    private static let imageColumns = """
    id, root_id, path, mtime, file_size, width, height, prompt_cache, source_platform, comfy_prompt_json, last_scanned_at
    """

    public func fetchImage(byPath path: String) throws -> ImageRecord? {
        try db.query(
            "SELECT \(Self.imageColumns) FROM images WHERE path = ?;",
            [.text(path)]
        ) { row in Self.mapRow(row) }.first
    }

    public func fetchImages(rootId: Int64? = nil) throws -> [ImageRecord] {
        if let rootId {
            return try db.query(
                "SELECT \(Self.imageColumns) FROM images WHERE root_id = ? ORDER BY path ASC;",
                [.integer(rootId)]
            ) { row in Self.mapRow(row) }
        }
        return try db.query(
            "SELECT \(Self.imageColumns) FROM images ORDER BY path ASC;"
        ) { row in Self.mapRow(row) }
    }

    /// 差分スキャンの「ファイルシステム上にあるパス一覧との突き合わせ」用に、
    /// パスだけを軽量に取得する。
    public func fetchAllPaths(rootId: Int64) throws -> [Int64: String] {
        let rows = try db.query(
            "SELECT id, path FROM images WHERE root_id = ?;",
            [.integer(rootId)]
        ) { row in (row.int64(0), row.string(1) ?? "") }
        return Dictionary(uniqueKeysWithValues: rows)
    }

    @discardableResult
    public func insertImage(
        rootId: Int64,
        path: String,
        mtime: Double,
        fileSize: Int64,
        width: Int?,
        height: Int?,
        promptCache: String?,
        sourcePlatform: ImageSourcePlatform = .unknown,
        comfyGenerationInfoJSON: String? = nil,
        lastScannedAt: Date = Date()
    ) throws -> Int64 {
        try db.run(
            """
            INSERT INTO images (root_id, path, mtime, file_size, width, height, prompt_cache, source_platform, comfy_prompt_json, last_scanned_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [
                .integer(rootId), .text(path), .real(mtime), .integer(fileSize),
                .from(width), .from(height), .from(promptCache),
                .text(sourcePlatform.rawValue), .from(comfyGenerationInfoJSON),
                .text(Self.isoFormatter.string(from: lastScannedAt))
            ]
        )
    }

    public func updateImage(
        id: Int64,
        mtime: Double,
        fileSize: Int64,
        width: Int?,
        height: Int?,
        promptCache: String?,
        sourcePlatform: ImageSourcePlatform = .unknown,
        comfyGenerationInfoJSON: String? = nil,
        lastScannedAt: Date = Date()
    ) throws {
        try db.run(
            """
            UPDATE images SET mtime = ?, file_size = ?, width = ?, height = ?, prompt_cache = ?,
                source_platform = ?, comfy_prompt_json = ?, last_scanned_at = ?
            WHERE id = ?;
            """,
            [
                .real(mtime), .integer(fileSize), .from(width), .from(height), .from(promptCache),
                .text(sourcePlatform.rawValue), .from(comfyGenerationInfoJSON),
                .text(Self.isoFormatter.string(from: lastScannedAt)), .integer(id)
            ]
        )
    }

    /// 孤児レコード（ファイルシステム上に実体が無いレコード）の一括削除。
    /// image_tagsはON DELETE CASCADEで連動削除される。
    public func deleteImages(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try db.transaction {
            for id in ids {
                try db.run("DELETE FROM images WHERE id = ?;", [.integer(id)])
            }
        }
    }

    private static func mapRow(_ row: DatabaseService.Row) -> ImageRecord {
        ImageRecord(
            id: row.int64(0),
            rootId: row.int64(1),
            path: row.string(2) ?? "",
            mtime: row.double(3),
            fileSize: row.int64(4),
            width: row.optionalInt(5),
            height: row.optionalInt(6),
            promptCache: row.optionalString(7),
            // 旧スキーマ由来・未スキャンのNULLは.unknownへ正規化する。
            sourcePlatform: row.optionalString(8).flatMap(ImageSourcePlatform.init(rawValue:)) ?? .unknown,
            comfyGenerationInfoJSON: row.optionalString(9),
            lastScannedAt: isoFormatter.date(from: row.string(10) ?? "") ?? Date(timeIntervalSince1970: 0)
        )
    }
}
