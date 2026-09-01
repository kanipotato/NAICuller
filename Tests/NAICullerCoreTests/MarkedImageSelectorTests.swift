import XCTest
@testable import NAICullerCore

/// 「削除対象」タグ付き画像の抽出のテスト。
/// 判定を間違えるとタグの付いていない画像をゴミ箱／バックアップフォルダへ移動してしまうため、
/// 「選択に紛れ込んだ未タグの画像は黙って除外する」という意図をここで固定する。
final class MarkedImageSelectorTests: XCTestCase {
    private func makeImage(id: Int64) -> ImageRecord {
        ImageRecord(
            id: id, rootId: 1, path: "/tmp/root/\(id).png", mtime: Double(id), fileSize: 1,
            width: nil, height: nil, promptCache: nil, sourcePlatform: .unknown, lastScannedAt: Date()
        )
    }

    private let images: [ImageRecord] = (1...5).map { id in
        ImageRecord(
            id: Int64(id), rootId: 1, path: "/tmp/root/\(id).png", mtime: Double(id), fileSize: 1,
            width: nil, height: nil, promptCache: nil, sourcePlatform: .unknown, lastScannedAt: Date()
        )
    }

    // MARK: - selected

    func testSelectedReturnsOnlyImagesThatAreBothSelectedAndMarked() {
        let result = MarkedImageSelector.selected(from: images, markedIds: [2, 3, 4], selectedIds: [3, 4, 5])
        XCTAssertEqual(result.map(\.id), [3, 4])
    }

    /// 選択に紛れ込んだ未タグの画像は対象外（これが漏れるとユーザーのファイルを勝手に動かす）。
    func testSelectedExcludesUnmarkedImagesEvenIfSelected() {
        let result = MarkedImageSelector.selected(from: images, markedIds: [1], selectedIds: [1, 2, 3])
        XCTAssertEqual(result.map(\.id), [1])
    }

    func testSelectedIsEmptyWhenNothingMarked() {
        XCTAssertTrue(MarkedImageSelector.selected(from: images, markedIds: [], selectedIds: [1, 2]).isEmpty)
    }

    func testSelectedIsEmptyWhenNothingSelected() {
        XCTAssertTrue(MarkedImageSelector.selected(from: images, markedIds: [1, 2], selectedIds: []).isEmpty)
    }

    /// 既に削除された等でimagesに存在しないIDが集合に混ざっていても落ちない。
    func testSelectedIgnoresIdsNotPresentInImages() {
        let result = MarkedImageSelector.selected(from: images, markedIds: [99], selectedIds: [99])
        XCTAssertTrue(result.isEmpty)
    }

    func testSelectedPreservesInputOrder() {
        let result = MarkedImageSelector.selected(from: images, markedIds: [5, 1, 3], selectedIds: [5, 1, 3])
        XCTAssertEqual(result.map(\.id), [1, 3, 5], "images の並び順を保つ")
    }

    // MARK: - all

    func testAllReturnsEveryMarkedImageRegardlessOfSelection() {
        let result = MarkedImageSelector.all(from: images, markedIds: [2, 5])
        XCTAssertEqual(result.map(\.id), [2, 5])
    }

    func testAllIsEmptyWhenNothingMarked() {
        XCTAssertTrue(MarkedImageSelector.all(from: images, markedIds: []).isEmpty)
    }

    func testAllPreservesInputOrder() {
        XCTAssertEqual(MarkedImageSelector.all(from: images, markedIds: [4, 1]).map(\.id), [1, 4])
    }
}
