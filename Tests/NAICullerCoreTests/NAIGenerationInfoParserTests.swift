import XCTest
@testable import NAICullerCore

/// `PNG:Comment`（NovelAI画像の生成パラメータJSON）のパースを検証する。
/// フィクスチャの構造は実際のNovelAI画像（`Tests/NAICullerCoreTests/Fixtures/sample1.png`、
/// `exiftool -j -G`で読み取り専用で調査）で確認したNovelAI Diffusion V4.5形式そのもの。
final class NAIGenerationInfoParserTests: XCTestCase {
    /// 実際のsample1.pngのPNG:Commentを圧縮した最小版（本質的なキーのみ残し、
    /// v4_prompt等の巨大な入れ子構造は省略。トップレベルのフラットなキーだけを見る
    /// 実装なので省略しても抽出結果は変わらない）。
    private let realisticCommentJSON = """
    {
      "prompt": "1girl, chibi, hyper detailed, star hair clip",
      "steps": 23,
      "height": 1216,
      "width": 832,
      "scale": 6.0,
      "uncond_scale": 0.0,
      "cfg_rescale": 0.0,
      "seed": 2073550565,
      "n_samples": 1,
      "noise_schedule": "karras",
      "sampler": "k_euler_ancestral",
      "sm": false,
      "sm_dyn": false,
      "uc": "blurry, lowres, bad anatomy, worst quality"
    }
    """

    func testExtractsAllFieldsFromRealisticComment() {
        let info = NAIGenerationInfoParser.extract(from: realisticCommentJSON)!
        XCTAssertEqual(info.seed, 2073550565)
        XCTAssertEqual(info.steps, 23)
        XCTAssertEqual(info.scale, 6.0)
        XCTAssertEqual(info.sampler, "k_euler_ancestral")
        XCTAssertEqual(info.noiseSchedule, "karras")
        XCTAssertEqual(info.smea, false)
        XCTAssertEqual(info.smDyn, false)
        XCTAssertEqual(info.negativePrompt, "blurry, lowres, bad anatomy, worst quality")
        XCTAssertFalse(info.isEmpty)
    }

    /// NovelAIのseedは符号なし32bit相当（最大約42億）まで届きうるため、Int32の範囲を
    /// 超える値でも壊れずに読めることを確認する（Int64で持っていることの裏付け）。
    func testSeedBeyondInt32RangeIsPreserved() {
        let json = #"{"seed": 4294967295}"#
        let info = NAIGenerationInfoParser.extract(from: json)!
        XCTAssertEqual(info.seed, 4294967295)
    }

    func testSmeaTrueIsParsedCorrectly() {
        let json = #"{"sm": true, "sm_dyn": true}"#
        let info = NAIGenerationInfoParser.extract(from: json)!
        XCTAssertEqual(info.smea, true)
        XCTAssertEqual(info.smDyn, true)
    }

    func testMalformedJSONReturnsNil() {
        XCTAssertNil(NAIGenerationInfoParser.extract(from: "not json"))
    }

    func testEmptyObjectReturnsAllNilButNotNilResult() {
        // パース自体は成功するが、中身が無いので.isEmptyがtrueになる
        // （呼び出し側=DetailPanelViewはisEmptyで「読み取れなかったよ」を出し分ける）。
        let info = NAIGenerationInfoParser.extract(from: "{}")!
        XCTAssertTrue(info.isEmpty)
    }

    func testComfyUIWorkflowJSONDoesNotAccidentallyMatch() {
        // ComfyUIのワークフローJSON（ノードグラフ）を誤って読んでも、"seed"等のトップレベル
        // キーは存在しないため空の結果になること（ジャンル違いのJSONを渡しても暴発しない）。
        let comfyJSON = #"{"KSampler.0": {"class_type": "KSampler", "inputs": {"seed": 1}}}"#
        let info = NAIGenerationInfoParser.extract(from: comfyJSON)!
        XCTAssertTrue(info.isEmpty)
    }
}
