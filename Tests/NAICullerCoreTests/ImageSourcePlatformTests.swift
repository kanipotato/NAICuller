import XCTest
@testable import NAICullerCore

/// `ImageSourcePlatform.detect(from:)`の判定ロジック（Stable Diffusion/ComfyUI対応）。
final class ImageSourcePlatformTests: XCTestCase {
    private let comfyWorkflowJSON = """
    {
      "CheckpointLoaderSimple.0": {
        "inputs": { "ckpt_name": "model.safetensors" },
        "class_type": "CheckpointLoaderSimple"
      }
    }
    """

    func testNovelAISoftwareWithDescriptionIsDetectedAsNovelAI() {
        let metadata = ExifMetadata(promptDescription: "1girl, chibi", width: nil, height: nil, software: "NovelAI", tagNames: [])
        XCTAssertEqual(ImageSourcePlatform.detect(from: metadata), .novelAI)
    }

    /// PNG:Softwareが"NovelAI"でも、PNG:Descriptionが読めていなければNovelAIと断定しない
    /// （壊れた/一部だけNovelAI由来のファイルを誤ってNovelAI扱いしないための保険）。
    func testNovelAISoftwareWithoutDescriptionIsNotDetectedAsNovelAI() {
        let metadata = ExifMetadata(promptDescription: nil, width: nil, height: nil, software: "NovelAI", tagNames: [])
        XCTAssertEqual(ImageSourcePlatform.detect(from: metadata), .unknown)
    }

    func testComfyUIWorkflowJSONIsDetectedAsComfyUI() {
        let metadata = ExifMetadata(promptDescription: nil, width: nil, height: nil, software: nil, comfyPromptJSON: comfyWorkflowJSON, tagNames: [])
        XCTAssertEqual(ImageSourcePlatform.detect(from: metadata), .comfyUI)
    }

    func testNeitherSignaturePresentIsUnknown() {
        let metadata = ExifMetadata(promptDescription: nil, width: nil, height: nil, software: nil, tagNames: [])
        XCTAssertEqual(ImageSourcePlatform.detect(from: metadata), .unknown)
    }

    /// NovelAI判定が優先されること（万一PNG:Promptに何か別の値が入っていても、
    /// PNG:Software=="NovelAI"が確実な方の判定を優先する）。
    func testNovelAISignatureTakesPriorityOverComfyUILikeContent() {
        let metadata = ExifMetadata(
            promptDescription: "1girl, chibi",
            width: nil, height: nil,
            software: "NovelAI",
            comfyPromptJSON: comfyWorkflowJSON,
            tagNames: []
        )
        XCTAssertEqual(ImageSourcePlatform.detect(from: metadata), .novelAI)
    }
}
