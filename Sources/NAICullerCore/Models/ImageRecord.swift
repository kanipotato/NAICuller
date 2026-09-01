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
    /// 生成元プラットフォーム（NovelAI／ComfyUI／不明）。スキャン時に`ImageSourcePlatform.detect`
    /// で判定して保存する。既定値`.unknown`は旧スキーマ・未スキャンの画像を表す。
    public var sourcePlatform: ImageSourcePlatform
    /// ComfyUI画像の生成情報の元データ（`PNG:Prompt`の生JSON文字列）。意図的に`promptCache`とは
    /// 別カラムに持たせている：`promptCache`はプロンプト検索・候補絞り込み機能が直接読む
    /// フィールドで、そこにJSONの塊が混ざると検索結果や候補一覧がゴミだらけになるため
    /// （プロンプト検索・候補絞り込みへのComfyUI統合は別タスクとして意図的に見送っている）。
    public var comfyGenerationInfoJSON: String?
    /// NovelAI画像の生成パラメータの元データ（`PNG:Comment`の生JSON文字列）。
    /// `comfyGenerationInfoJSON`と同じ理由で`promptCache`とは別カラムに持たせている。
    public var naiGenerationInfoJSON: String?
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
        sourcePlatform: ImageSourcePlatform = .unknown,
        comfyGenerationInfoJSON: String? = nil,
        naiGenerationInfoJSON: String? = nil,
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
        self.sourcePlatform = sourcePlatform
        self.comfyGenerationInfoJSON = comfyGenerationInfoJSON
        self.naiGenerationInfoJSON = naiGenerationInfoJSON
        self.lastScannedAt = lastScannedAt
    }

    public var url: URL {
        URL(fileURLWithPath: path)
    }
}
