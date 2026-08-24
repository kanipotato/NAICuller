import Foundation

/// NovelAI画像の`PNG:Comment`から抽出した生成パラメータ。実データ調査で確認したNovelAI
/// Diffusion V4.5形式のJSON（`{"prompt": ..., "seed": ..., "steps": ..., "scale": ...,
/// "sampler": ..., "noise_schedule": ..., "sm": ..., "sm_dyn": ..., "uc": ..., ...}`）を
/// フラットなトップレベルキーからそのまま拾う。ExifToolのフィクスチャ画像
/// （Tests/NAICullerCoreTests/Fixtures/sample1.png）で実際の構造を確認済み。
public struct NAIGenerationInfo: Equatable, Sendable {
    /// 「NovelAIの履歴を消しても、この値さえあれば同じ画像を起点に再生成できる」ための核心情報
    /// （実際に使ってみてのフィードバックで追加）。
    public var seed: Int64?
    public var steps: Int?
    /// CFG Scale相当（NovelAIの表記に合わせて`scale`のまま持つ）。
    public var scale: Double?
    public var sampler: String?
    public var noiseSchedule: String?
    /// SMEA / SMEA DYN。NovelAI UI上のチェックボックスに対応し、再現には値も必要。
    public var smea: Bool?
    public var smDyn: Bool?
    /// "uc" = undesired content（ネガティブプロンプト）。
    public var negativePrompt: String?

    public var isEmpty: Bool {
        seed == nil && steps == nil && scale == nil && sampler == nil
            && noiseSchedule == nil && smea == nil && smDyn == nil && negativePrompt == nil
    }
}

public enum NAIGenerationInfoParser {
    public static func extract(from jsonString: String) -> NAIGenerationInfo? {
        guard let data = jsonString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        return NAIGenerationInfo(
            seed: (object["seed"] as? NSNumber)?.int64Value,
            steps: (object["steps"] as? NSNumber)?.intValue,
            scale: (object["scale"] as? NSNumber)?.doubleValue,
            sampler: object["sampler"] as? String,
            noiseSchedule: object["noise_schedule"] as? String,
            smea: object["sm"] as? Bool,
            smDyn: object["sm_dyn"] as? Bool,
            negativePrompt: object["uc"] as? String
        )
    }
}
