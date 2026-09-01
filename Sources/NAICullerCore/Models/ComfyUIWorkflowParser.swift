import Foundation

/// ComfyUIのLoRA読み込み1件（モデル名＋強度）。
public struct ComfyUILoRAEntry: Equatable, Hashable, Sendable {
    public var name: String
    public var strengthModel: Double
    public var strengthClip: Double
}

/// ComfyUIのKSamplerノード1件分の生成パラメータ。
public struct ComfyUISamplerParams: Equatable, Hashable, Sendable {
    public var seed: Int64
    public var steps: Int
    public var cfg: Double
    public var samplerName: String
    public var scheduler: String
}

/// ポジティブ・ネガティブのプロンプト組。KSamplerのinputs.positive/negativeが参照する
/// CLIPTextEncodeノードを辿って対応付けたもの（単純に全CLIPTextEncodeを羅列すると、
/// どれがポジでどれがネガか分からなくなるため）。
public struct ComfyUIPromptPair: Equatable, Hashable, Sendable {
    public var positive: String
    public var negative: String
}

/// 1枚のPNGから抽出したComfyUIの生成情報。ノード種別ごとに集計し重複除去したもの。
///
/// 意図的に「このファイル1枚がどのノードクラスタを使ったか」の厳密な特定はしない
/// （実データ調査で判明：1枚のグラフに複数バッチ分のノードが記録されているケースがあり、
/// ファイル内の情報だけでは一意に絞れないことがあるため。詳細はNotion開発ログ参照）。
/// 見つかった分だけ正直にリスト表示する、という設計方針。
public struct ComfyUIGenerationInfo: Equatable, Sendable {
    public var checkpoints: [String]
    public var loras: [ComfyUILoRAEntry]
    public var samplerParams: [ComfyUISamplerParams]
    public var promptPairs: [ComfyUIPromptPair]

    public var isEmpty: Bool {
        checkpoints.isEmpty && loras.isEmpty && samplerParams.isEmpty && promptPairs.isEmpty
    }
}

/// `PNG:Prompt`に埋め込まれたComfyUIのAPIフォーマット・ワークフロー（ノードグラフのJSON）を
/// パースする。グラフの形は`{"<nodeId>": {"class_type": "...", "inputs": {...}}, ...}`
/// （実際のLoRA検証画像で確認済み）。
public enum ComfyUIWorkflowParser {
    /// 文字列がComfyUIのワークフローJSONとしてパース可能かどうか（生成元判定に使う）。
    public static func isComfyUIWorkflow(_ jsonString: String) -> Bool {
        parseNodes(jsonString) != nil
    }

    /// ノード種別ごとに生成情報を抽出する。パース不能なら`nil`。
    public static func extractGenerationInfo(from jsonString: String) -> ComfyUIGenerationInfo? {
        guard let nodes = parseNodes(jsonString) else { return nil }

        var checkpoints: [String] = []
        var loras: [ComfyUILoRAEntry] = []
        var samplerParams: [ComfyUISamplerParams] = []
        var promptPairs: [ComfyUIPromptPair] = []

        for (_, node) in nodes {
            guard let classType = node["class_type"] as? String,
                  let inputs = node["inputs"] as? [String: Any] else { continue }

            switch classType {
            case "CheckpointLoaderSimple":
                if let name = inputs["ckpt_name"] as? String, !checkpoints.contains(name) {
                    checkpoints.append(name)
                }

            case "LoraLoader":
                if let name = inputs["lora_name"] as? String {
                    let entry = ComfyUILoRAEntry(
                        name: name,
                        strengthModel: doubleValue(inputs["strength_model"]) ?? 1.0,
                        strengthClip: doubleValue(inputs["strength_clip"]) ?? 1.0
                    )
                    if !loras.contains(entry) { loras.append(entry) }
                }

            case "KSampler":
                if let seed = int64Value(inputs["seed"]),
                   let steps = intValue(inputs["steps"]),
                   let cfg = doubleValue(inputs["cfg"]),
                   let samplerName = inputs["sampler_name"] as? String,
                   let scheduler = inputs["scheduler"] as? String {
                    let params = ComfyUISamplerParams(
                        seed: seed, steps: steps, cfg: cfg,
                        samplerName: samplerName, scheduler: scheduler
                    )
                    if !samplerParams.contains(params) { samplerParams.append(params) }
                }
                if let positive = text(referencedBy: inputs["positive"], in: nodes),
                   let negative = text(referencedBy: inputs["negative"], in: nodes) {
                    let pair = ComfyUIPromptPair(positive: positive, negative: negative)
                    if !promptPairs.contains(pair) { promptPairs.append(pair) }
                }

            default:
                break
            }
        }

        return ComfyUIGenerationInfo(
            checkpoints: checkpoints, loras: loras,
            samplerParams: samplerParams, promptPairs: promptPairs
        )
    }

    /// ComfyUIのAPIフォーマットでは、ノード間の接続は`["<参照先ノードID>", <出力スロット番号>]`
    /// という2要素配列で表現される。参照先ノードの`inputs.text`（CLIPTextEncodeの文言）を返す。
    private static func text(referencedBy value: Any?, in nodes: [String: [String: Any]]) -> String? {
        guard let ref = value as? [Any], let nodeId = ref.first as? String,
              let targetInputs = nodes[nodeId]?["inputs"] as? [String: Any] else { return nil }
        return targetInputs["text"] as? String
    }

    /// トップレベルの全エントリが`{"class_type": ..., "inputs": {...}}`の形をしているか確認しつつパースする。
    /// これがComfyUIのワークフローらしさの判定基準そのもの（他形式のJSONとの誤判定を避けるため厳密にする）。
    private static func parseNodes(_ jsonString: String) -> [String: [String: Any]]? {
        guard let data = jsonString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !object.isEmpty else { return nil }
        var nodes: [String: [String: Any]] = [:]
        for (key, value) in object {
            guard let node = value as? [String: Any], node["class_type"] is String else { return nil }
            nodes[key] = node
        }
        return nodes
    }

    private static func doubleValue(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
    private static func intValue(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }
    private static func int64Value(_ value: Any?) -> Int64? { (value as? NSNumber)?.int64Value }
}
