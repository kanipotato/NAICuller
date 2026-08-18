import XCTest
@testable import NAICullerCore

/// `AppModel.refreshFilteredImages()`から切り出した絞り込みロジックのテスト。
/// 元は`AppModel`（@MainActor + DB/ExifTool依存）の中にあり単体で確かめられなかったため、
/// 条件の組み合わせ（特に「未タグのみ」とタグ絞り込みの優先順位、削除対象の除外）を
/// ここで固定する。
final class ImageFilterTests: XCTestCase {
    private func makeImage(id: Int64, rootId: Int64 = 1, prompt: String? = nil) -> ImageRecord {
        ImageRecord(
            id: id,
            rootId: rootId,
            path: "/tmp/root/\(id).png",
            mtime: Double(id),
            fileSize: 100,
            width: nil,
            height: nil,
            promptCache: prompt,
            lastScannedAt: Date()
        )
    }

    /// プロンプト候補絞り込みを使わないテストでは呼ばれない想定なので、呼ばれたら失敗させる。
    private func unusedPromptTerms(_ image: ImageRecord) -> Set<String> {
        XCTFail("selectedPromptTermsが空のときはpromptTermsを呼ばないはず")
        return []
    }

    private func apply(
        _ images: [ImageRecord],
        tags: [Int64: Set<Int64>] = [:],
        criteria: ImageFilterCriteria,
        promptTerms: ((ImageRecord) -> Set<String>)? = nil
    ) -> [Int64] {
        ImageFilter.apply(
            to: images,
            imageTagIds: tags,
            criteria: criteria,
            promptTerms: promptTerms ?? unusedPromptTerms
        ).map(\.id)
    }

    // MARK: - ルート

    func testImagesOutsideEnabledRootsAreExcluded() {
        let images = [makeImage(id: 1, rootId: 1), makeImage(id: 2, rootId: 2)]
        let result = apply(images, criteria: ImageFilterCriteria(enabledRootIds: [1]))
        XCTAssertEqual(result, [1])
    }

    func testEmptyEnabledRootsExcludesEverything() {
        let images = [makeImage(id: 1, rootId: 1), makeImage(id: 2, rootId: 2)]
        let result = apply(images, criteria: ImageFilterCriteria(enabledRootIds: []))
        XCTAssertEqual(result, [])
    }

    // MARK: - タグ絞り込み（AND条件）

    func testSelectedTagsRequireAllTagsPresent() {
        let images = [makeImage(id: 1), makeImage(id: 2), makeImage(id: 3)]
        let tags: [Int64: Set<Int64>] = [1: [10, 20], 2: [10], 3: [10, 20, 30]]
        let result = apply(
            images,
            tags: tags,
            criteria: ImageFilterCriteria(enabledRootIds: [1], selectedTagIds: [10, 20])
        )
        // 2は20を持たないので落ちる。3は余分に30を持つが、部分集合条件なので残る。
        XCTAssertEqual(result, [1, 3])
    }

    func testImageWithNoTagEntryIsExcludedWhenTagsSelected() {
        let images = [makeImage(id: 1)]
        let result = apply(
            images,
            tags: [:],
            criteria: ImageFilterCriteria(enabledRootIds: [1], selectedTagIds: [10])
        )
        XCTAssertEqual(result, [])
    }

    // MARK: - 未タグのみ表示（タグ絞り込みより優先）

    func testShowUntaggedOnlyKeepsImagesWithoutTags() {
        let images = [makeImage(id: 1), makeImage(id: 2)]
        let tags: [Int64: Set<Int64>] = [1: [10], 2: []]
        let result = apply(
            images,
            tags: tags,
            criteria: ImageFilterCriteria(enabledRootIds: [1], showUntaggedOnly: true)
        )
        XCTAssertEqual(result, [2])
    }

    func testShowUntaggedOnlyTakesPrecedenceOverSelectedTags() {
        let images = [makeImage(id: 1), makeImage(id: 2)]
        let tags: [Int64: Set<Int64>] = [1: [10], 2: []]
        // UI上は排他だが、両方立った状態でも「未タグのみ」が勝つことを固定する。
        let result = apply(
            images,
            tags: tags,
            criteria: ImageFilterCriteria(enabledRootIds: [1], selectedTagIds: [10], showUntaggedOnly: true)
        )
        XCTAssertEqual(result, [2])
    }

    // MARK: - 削除対象の除外

    func testDeletionMarkedImagesAreExcludedWhenHidden() {
        let images = [makeImage(id: 1), makeImage(id: 2)]
        let tags: [Int64: Set<Int64>] = [1: [99], 2: [10]]
        let result = apply(
            images,
            tags: tags,
            criteria: ImageFilterCriteria(enabledRootIds: [1], hiddenDeletionMarkTagId: 99)
        )
        XCTAssertEqual(result, [2])
    }

    func testDeletionMarkedImagesRemainWhenNotHidden() {
        let images = [makeImage(id: 1), makeImage(id: 2)]
        let tags: [Int64: Set<Int64>] = [1: [99], 2: [10]]
        let result = apply(
            images,
            tags: tags,
            criteria: ImageFilterCriteria(enabledRootIds: [1], hiddenDeletionMarkTagId: nil)
        )
        XCTAssertEqual(result, [1, 2])
    }

    /// 「未タグのみ表示」と「削除対象を隠す」は独立に効く（削除対象タグが付いていれば未タグではないので、
    /// 実際には未タグ側で先に落ちる）ことの確認。
    func testUntaggedOnlyAndHideDeletionMarkedCombine() {
        let images = [makeImage(id: 1), makeImage(id: 2)]
        let tags: [Int64: Set<Int64>] = [1: [99], 2: []]
        let result = apply(
            images,
            tags: tags,
            criteria: ImageFilterCriteria(enabledRootIds: [1], showUntaggedOnly: true, hiddenDeletionMarkTagId: 99)
        )
        XCTAssertEqual(result, [2])
    }

    // MARK: - プロンプト検索

    func testPromptSearchIsCaseInsensitiveSubstringMatch() {
        let images = [
            makeImage(id: 1, prompt: "1girl, Cat Ears, chibi"),
            makeImage(id: 2, prompt: "1boy, dog"),
            makeImage(id: 3, prompt: nil)
        ]
        let result = apply(
            images,
            criteria: ImageFilterCriteria(enabledRootIds: [1], promptSearchText: "cat ears")
        )
        XCTAssertEqual(result, [1])
    }

    func testImageWithoutPromptIsExcludedWhenSearching() {
        let images = [makeImage(id: 1, prompt: nil)]
        let result = apply(
            images,
            criteria: ImageFilterCriteria(enabledRootIds: [1], promptSearchText: "cat")
        )
        XCTAssertEqual(result, [])
    }

    // MARK: - プロンプト候補絞り込み（AND条件）

    func testSelectedPromptTermsRequireAllTerms() {
        let images = [
            makeImage(id: 1, prompt: "1girl, cat ears"),
            makeImage(id: 2, prompt: "1girl"),
            makeImage(id: 3, prompt: nil)
        ]
        let terms: [Int64: Set<String>] = [1: ["1girl", "cat ears"], 2: ["1girl"]]
        let result = apply(
            images,
            criteria: ImageFilterCriteria(enabledRootIds: [1], selectedPromptTerms: ["1girl", "cat ears"]),
            promptTerms: { terms[$0.id] ?? [] }
        )
        XCTAssertEqual(result, [1])
    }

    func testPromptTermsClosureIsNotCalledWhenNoTermsSelected() {
        let images = [makeImage(id: 1, prompt: "1girl")]
        // promptTermsにunusedPromptTerms（呼ばれたらXCTFail）を使う。
        let result = apply(images, criteria: ImageFilterCriteria(enabledRootIds: [1]))
        XCTAssertEqual(result, [1])
    }

    // MARK: - 複合

    func testAllCriteriaCombineAsAnd() {
        let images = [
            makeImage(id: 1, rootId: 1, prompt: "1girl, cat ears"),
            makeImage(id: 2, rootId: 1, prompt: "1girl, cat ears"), // 削除対象タグ付きで落ちる
            makeImage(id: 3, rootId: 2, prompt: "1girl, cat ears"), // ルート外で落ちる
            makeImage(id: 4, rootId: 1, prompt: "1boy")             // プロンプト検索で落ちる
        ]
        let tags: [Int64: Set<Int64>] = [1: [10], 2: [10, 99], 3: [10], 4: [10]]
        let result = apply(
            images,
            tags: tags,
            criteria: ImageFilterCriteria(
                enabledRootIds: [1],
                selectedTagIds: [10],
                hiddenDeletionMarkTagId: 99,
                promptSearchText: "cat",
                selectedPromptTerms: ["cat ears"]
            ),
            promptTerms: { Set(($0.promptCache ?? "").components(separatedBy: ", ")) }
        )
        XCTAssertEqual(result, [1])
    }

    func testEmptyCriteriaKeepsOrderOfInput() {
        let images = [makeImage(id: 3), makeImage(id: 1), makeImage(id: 2)]
        // 並び替えはImageSortOrderの責務なので、フィルタは入力順を保つ。
        let result = apply(images, criteria: ImageFilterCriteria(enabledRootIds: [1]))
        XCTAssertEqual(result, [3, 1, 2])
    }
}
