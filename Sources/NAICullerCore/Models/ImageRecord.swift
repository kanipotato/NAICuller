import Foundation

/// 画像1枚分のスキャン結果キャッシュ（`images`テーブル1行に対応）。
///
/// `promptCache`はあくまで表示高速化用のキャッシュであり正データではない。
/// 正データは常に画像ファイル側のメタデータ（PNG:Description / XMP:Subject）。
/// DBが壊れても再スキャンで復元できることを前提にしている（詳細設計 3章）。
public struct ImageRecord: Equatable, Identifiable, Sendable {
    public var id: Int64
    public var rootId: Int64
    public var path: String
    public var mtime: Double
    public var fileSize: Int64
    public var width: Int?
    public var height: Int?
    public var promptCache: String?
    public var lastScannedAt: Date

    public init(
        id: Int64,
        rootId: Int64,
        path: String,
        mtime: Double,
        fileSize: Int64,
        width: Int?,
        height: Int?,
        promptCache: String?,
        lastScannedAt: Date
    ) {
        self.id = id
        self.rootId = rootId
        self.path = path
        self.mtime = mtime
        self.fileSize = fileSize
        self.width = width
        self.height = height
        self.promptCache = promptCache
        self.lastScannedAt = lastScannedAt
    }

    public var url: URL {
        URL(fileURLWithPath: path)
    }
}
