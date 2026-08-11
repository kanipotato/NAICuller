import Foundation

/// `tags`テーブル・`image_tags`テーブルへのアクセスをまとめたリポジトリ。
public final class TagRepository {
    private let db: DatabaseService

    public init(db: DatabaseService) {
        self.db = db
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // MARK: - tags

    public func fetchAll() throws -> [Tag] {
        try db.query(
            "SELECT id, name, is_system, key_binding FROM tags ORDER BY is_system DESC, name ASC;"
        ) { row in
            Tag(
                id: row.int64(0),
                name: row.string(1) ?? "",
                isSystem: row.int(2) != 0,
                keyBinding: row.optionalString(3)
            )
        }
    }

    public func fetchByKeyBinding(_ key: String) throws -> Tag? {
        try db.query(
            "SELECT id, name, is_system, key_binding FROM tags WHERE key_binding = ?;",
            [.text(key)]
        ) { row in
            Tag(id: row.int64(0), name: row.string(1) ?? "", isSystem: row.int(2) != 0, keyBinding: row.optionalString(3))
        }.first
    }

    /// 大文字小文字を区別しない既存タグ検索。自由入力タグは「同名なら既存に紐付け、新規作成しない」ため使用する。
    public func fetchByNameCaseInsensitive(_ name: String) throws -> Tag? {
        try db.query(
            "SELECT id, name, is_system, key_binding FROM tags WHERE name = ? COLLATE NOCASE;",
            [.text(name)]
        ) { row in
            Tag(id: row.int64(0), name: row.string(1) ?? "", isSystem: row.int(2) != 0, keyBinding: row.optionalString(3))
        }.first
    }

    /// ユーザー定義タグを新規作成する。呼び出し側は事前に`TagNameValidator`で検証し、
    /// `fetchByNameCaseInsensitive`で重複が無いことを確認してから呼ぶこと。
    @discardableResult
    public func insertUserTag(name: String, keyBinding: String? = nil) throws -> Int64 {
        try db.run(
            "INSERT INTO tags (name, is_system, key_binding) VALUES (?, 0, ?);",
            [.text(name), .from(keyBinding)]
        )
    }

    /// カスタムタグ（1〜9）のキー割当を更新する。呼び出し側で「同じキーへの重複割当は上書き確認」の
    /// UIフローを済ませ、必要なら先に`clearKeyBinding`で旧タグの割当を外してから呼ぶこと。
    /// （key_bindingにUNIQUE制約があるため、外さずに呼ぶとDatabaseErrorになる。）
    public func setKeyBinding(tagId: Int64, keyBinding: String?) throws {
        try db.run(
            "UPDATE tags SET key_binding = ? WHERE id = ?;",
            [.from(keyBinding), .integer(tagId)]
        )
    }

    public func clearKeyBinding(tagId: Int64) throws {
        try setKeyBinding(tagId: tagId, keyBinding: nil)
    }

    // MARK: - image_tags

    public func tagIds(forImage imageId: Int64) throws -> Set<Int64> {
        let ids = try db.query(
            "SELECT tag_id FROM image_tags WHERE image_id = ?;",
            [.integer(imageId)]
        ) { row in row.int64(0) }
        return Set(ids)
    }

    public func tags(forImage imageId: Int64) throws -> [Tag] {
        try db.query(
            """
            SELECT t.id, t.name, t.is_system, t.key_binding
            FROM tags t
            JOIN image_tags it ON it.tag_id = t.id
            WHERE it.image_id = ?
            ORDER BY t.is_system DESC, t.name ASC;
            """,
            [.integer(imageId)]
        ) { row in
            Tag(id: row.int64(0), name: row.string(1) ?? "", isSystem: row.int(2) != 0, keyBinding: row.optionalString(3))
        }
    }

    public func addTagToImage(imageId: Int64, tagId: Int64, taggedAt: Date = Date()) throws {
        try db.run(
            "INSERT OR IGNORE INTO image_tags (image_id, tag_id, tagged_at) VALUES (?, ?, ?);",
            [.integer(imageId), .integer(tagId), .text(Self.isoFormatter.string(from: taggedAt))]
        )
    }

    public func removeTagFromImage(imageId: Int64, tagId: Int64) throws {
        try db.run(
            "DELETE FROM image_tags WHERE image_id = ? AND tag_id = ?;",
            [.integer(imageId), .integer(tagId)]
        )
    }

    /// 指定タグが付いている画像IDの集合（絞り込みUI用）。
    public func imageIds(taggedWith tagId: Int64) throws -> Set<Int64> {
        let ids = try db.query(
            "SELECT image_id FROM image_tags WHERE tag_id = ?;",
            [.integer(tagId)]
        ) { row in row.int64(0) }
        return Set(ids)
    }

    /// サイドバーのタグ一覧に添える件数（タグごとに紐付いている画像数）。
    public func tagCounts() throws -> [Int64: Int] {
        let rows = try db.query(
            "SELECT tag_id, COUNT(*) FROM image_tags GROUP BY tag_id;"
        ) { row in (row.int64(0), row.int(1)) }
        return Dictionary(uniqueKeysWithValues: rows)
    }

    /// 全画像分のタグID集合をimage_tagsテーブル1回のSELECTでまとめて取得する
    /// （コードレビュー指摘：`tagIds(forImage:)`を画像1件ずつループで呼ぶN+1クエリの解消用。
    /// `reloadImages()`はこれまで画像枚数と同じ回数SQLiteへ問い合わせていた）。
    public func allImageTagIds() throws -> [Int64: Set<Int64>] {
        let rows = try db.query(
            "SELECT image_id, tag_id FROM image_tags;"
        ) { row in (row.int64(0), row.int64(1)) }
        var mapping: [Int64: Set<Int64>] = [:]
        for (imageId, tagId) in rows {
            mapping[imageId, default: []].insert(tagId)
        }
        return mapping
    }
}
