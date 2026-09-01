import XCTest
@testable import NAICullerCore

/// `PNG:Prompt`（ComfyUIのAPIフォーマット・ワークフローJSON）のパースを検証する。
/// フィクスチャは実際のLoRA検証画像（ユーザー提供、`/Users/kazu/Dev/work/novelAI/LoRA検証結果`）を
/// 読み取り専用で調査して確認した実際の構造を元にしている（Notion開発ログ参照）。
final class ComfyUIWorkflowParserTests: XCTestCase {
    /// LoRA比較検証のように、1グラフに2バッチ分のノードが入っているケースを模したフィクスチャ。
    /// プロンプトは2バッチとも同一（実際のユーザーのLoRA検証と同じ状況）、LoRA名だけ違う。
    private let twoLoRABatchJSON = """
    {
      "CheckpointLoaderSimple.0": {
        "inputs": { "ckpt_name": "waiIllustriousSDXL_v170.safetensors" },
        "class_type": "CheckpointLoaderSimple"
      },
      "LoraLoader.0": {
        "inputs": {
          "lora_name": "orangecat_step200_kohya.safetensors",
          "strength_model": 1.0, "strength_clip": 1.0,
          "model": ["CheckpointLoaderSimple.0", 0], "clip": ["CheckpointLoaderSimple.0", 1]
        },
        "class_type": "LoraLoader"
      },
      "CLIPTextEncode.0": {
        "inputs": { "text": "1girl, chibi, orange hair", "clip": ["LoraLoader.0", 1] },
        "class_type": "CLIPTextEncode"
      },
      "CLIPTextEncode.1": {
        "inputs": { "text": "bad quality, worst quality", "clip": ["LoraLoader.0", 1] },
        "class_type": "CLIPTextEncode"
      },
      "KSampler.0": {
        "inputs": {
          "seed": 12345, "steps": 22, "cfg": 6.0,
          "sampler_name": "euler_ancestral", "scheduler": "normal", "denoise": 1.0,
          "model": ["LoraLoader.0", 0],
          "positive": ["CLIPTextEncode.0", 0], "negative": ["CLIPTextEncode.1", 0],
          "latent_image": ["EmptyLatentImage.0", 0]
        },
        "class_type": "KSampler"
      },
      "LoraLoader.1": {
        "inputs": {
          "lora_name": "orangecat_step400_kohya.safetensors",
          "strength_model": 1.0, "strength_clip": 1.0,
          "model": ["CheckpointLoaderSimple.0", 0], "clip": ["CheckpointLoaderSimple.0", 1]
        },
        "class_type": "LoraLoader"
      },
      "CLIPTextEncode.2": {
        "inputs": { "text": "1girl, chibi, orange hair", "clip": ["LoraLoader.1", 1] },
        "class_type": "CLIPTextEncode"
      },
      "CLIPTextEncode.3": {
        "inputs": { "text": "bad quality, worst quality", "clip": ["LoraLoader.1", 1] },
        "class_type": "CLIPTextEncode"
      },
      "KSampler.1": {
        "inputs": {
          "seed": 12345, "steps": 22, "cfg": 6.0,
          "sampler_name": "euler_ancestral", "scheduler": "normal", "denoise": 1.0,
          "model": ["LoraLoader.1", 0],
          "positive": ["CLIPTextEncode.2", 0], "negative": ["CLIPTextEncode.3", 0],
          "latent_image": ["EmptyLatentImage.0", 0]
        },
        "class_type": "KSampler"
      }
    }
    """

    // MARK: - isComfyUIWorkflow（生成元判定）

    func testValidWorkflowJSONIsRecognized() {
        XCTAssertTrue(ComfyUIWorkflowParser.isComfyUIWorkflow(twoLoRABatchJSON))
    }

    func testArbitraryJSONWithoutClassTypeIsNotRecognized() {
        // NovelAIのPNG:Commentのような、ComfyUIと無関係なJSONを誤検出しないこと。
        XCTAssertFalse(ComfyUIWorkflowParser.isComfyUIWorkflow(#"{"prompt": "1girl", "steps": 28}"#))
    }

    func testMalformedJSONIsNotRecognized() {
        XCTAssertFalse(ComfyUIWorkflowParser.isComfyUIWorkflow("not json at all"))
    }

    func testEmptyObjectIsNotRecognized() {
        XCTAssertFalse(ComfyUIWorkflowParser.isComfyUIWorkflow("{}"))
    }

    // MARK: - extractGenerationInfo

    func testExtractsCheckpointDeduped() {
        let info = ComfyUIWorkflowParser.extractGenerationInfo(from: twoLoRABatchJSON)!
        // 2バッチとも同じチェックポイントを参照しているので1件に重複除去される。
        XCTAssertEqual(info.checkpoints, ["waiIllustriousSDXL_v170.safetensors"])
    }

    /// 実データで確認した中核ケース：LoRAだけ変えてプロンプトは固定、という比較検証だと
    /// LoRAは複数件・プロンプトは1件に集約される（ユーザーとの合意事項通りの挙動）。
    func testExtractsMultipleLoRAsButDedupsIdenticalPrompts() {
        let info = ComfyUIWorkflowParser.extractGenerationInfo(from: twoLoRABatchJSON)!
        XCTAssertEqual(info.loras.count, 2)
        XCTAssertTrue(info.loras.contains(ComfyUILoRAEntry(name: "orangecat_step200_kohya.safetensors", strengthModel: 1.0, strengthClip: 1.0)))
        XCTAssertTrue(info.loras.contains(ComfyUILoRAEntry(name: "orangecat_step400_kohya.safetensors", strengthModel: 1.0, strengthClip: 1.0)))

        XCTAssertEqual(info.promptPairs, [
            ComfyUIPromptPair(positive: "1girl, chibi, orange hair", negative: "bad quality, worst quality")
        ])
    }

    func testExtractsSamplerParamsDeduped() {
        let info = ComfyUIWorkflowParser.extractGenerationInfo(from: twoLoRABatchJSON)!
        // 両KSamplerともseed/steps/cfg/sampler/schedulerが完全一致なので1件に集約される。
        XCTAssertEqual(info.samplerParams, [
            ComfyUISamplerParams(seed: 12345, steps: 22, cfg: 6.0, samplerName: "euler_ancestral", scheduler: "normal")
        ])
    }

    /// KSamplerのpositive/negative参照を正しく辿れていることの確認：ポジとネガを取り違えていないか。
    func testPromptPairDoesNotSwapPositiveAndNegative() {
        let json = """
        {
          "CLIPTextEncode.pos": { "inputs": { "text": "POSITIVE_TEXT" }, "class_type": "CLIPTextEncode" },
          "CLIPTextEncode.neg": { "inputs": { "text": "NEGATIVE_TEXT" }, "class_type": "CLIPTextEncode" },
          "KSampler.0": {
            "inputs": {
              "seed": 1, "steps": 1, "cfg": 1.0, "sampler_name": "euler", "scheduler": "normal",
              "positive": ["CLIPTextEncode.pos", 0], "negative": ["CLIPTextEncode.neg", 0]
            },
            "class_type": "KSampler"
          }
        }
        """
        let info = ComfyUIWorkflowParser.extractGenerationInfo(from: json)!
        XCTAssertEqual(info.promptPairs, [ComfyUIPromptPair(positive: "POSITIVE_TEXT", negative: "NEGATIVE_TEXT")])
    }

    func testUnparsableJSONReturnsNil() {
        XCTAssertNil(ComfyUIWorkflowParser.extractGenerationInfo(from: "not json"))
    }

    func testEmptyGenerationInfoReportsIsEmpty() {
        let info = ComfyUIGenerationInfo(checkpoints: [], loras: [], samplerParams: [], promptPairs: [])
        XCTAssertTrue(info.isEmpty)
    }
}
