import Foundation

/// 画像の生成元プラットフォーム。サイドバーの絞り込み・右パネルの表示切り替えに使う
/// （実際に使ってみてのフィードバックで追加：Stable Diffusion(ComfyUI)の画像も扱いたいが、
/// NovelAIとはメタデータの構造が根本的に違うため、画像ごとに自動判定して出し分ける方式にした）。
///
/// DBには常に`rawValue`を書き込む（NULL許容だが、書き込み時にnilは使わない）。
/// 未判定・旧スキーマ由来のNULLは読み取り時に`.unknown`へ正規化する（`ImageRepository`参照）。
public enum ImageSourcePlatform: String, CaseIterable, Identifiable, Sendable, Equatable {
    case novelAI = "novelai"
    case comfyUI = "comfyui"
    case unknown = "unknown"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .novelAI: return "NovelAI"
        case .comfyUI: return "ComfyUI"
        case .unknown: return "不明"
        }
    }

    /// ExifToolで読んだメタデータから生成元を判定する。
    /// - NovelAI: `PNG:Software`が"NovelAI"、かつ`PNG:Description`が読める
    /// - ComfyUI: `PNG:Prompt`がComfyUIのAPIフォーマット・ワークフロー（ノードグラフ）として
    ///   パース可能（実データ調査で確認：`{"<nodeId>": {"class_type": "...", "inputs": {...}}, ...}`
    ///   という形。1枚のJSONに複数ノードクラスタ分の設定が入りうる）
    /// - どちらでもなければ`.unknown`
    public static func detect(from metadata: ExifMetadata) -> ImageSourcePlatform {
        if metadata.software == "NovelAI", metadata.promptDescription != nil {
            return .novelAI
        }
        if let comfyPromptJSON = metadata.comfyPromptJSON, ComfyUIWorkflowParser.isComfyUIWorkflow(comfyPromptJSON) {
            return .comfyUI
        }
        return .unknown
    }
}
