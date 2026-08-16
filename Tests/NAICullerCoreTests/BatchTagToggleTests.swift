import XCTest
@testable import NAICullerCore

/// 複数選択時の一括タグ付けのトライステート判断（`AppModel`から切り出したもの）のテスト。
/// 「全部付いている時だけ外す」「既に目的の状態のものは触らない」という仕様を固定する。
final class BatchTagToggleTests: XCTestCase {
    private func makeImage(id: Int64) -> ImageRecord {
        ImageRecord(
            id: id, rootId: 1, path: "/tmp/root/\(id).png", mtime: Double(id),
            fileSize: 1, width: nil, height: nil, promptCache: nil, lastScannedAt: Date()
        )
    }

    func testAddsWhenNoneTagged() {
        let images = [makeImage(id: 1), makeImage(id: 2)]
        let plan = BatchTagToggle.plan(images: images, tagId: 10, imageTagIds: [:])
        XCTAssertTrue(plan.shouldAdd)
        XCTAssertEqual(plan.targets.map(\.id), [1, 2])
    }

    /// 1件でも未タグがあれば「全部に付ける」側に倒れる。
    func testAddsWhenPartiallyTagged() {
        let images = [makeImage(id: 1), makeImage(id: 2), makeImage(id: 3)]
        let plan = BatchTagToggle.plan(images: images, tagId: 10, imageTagIds: [1: [10], 3: [10]])
        XCTAssertTrue(plan.shouldAdd)
        // 既に付いている1と3は触らない（無駄なExifTool書き込みを避ける）。
        XCTAssertEqual(plan.targets.map(\.id), [2])
    }

    func testRemovesOnlyWhenAllTagged() {
        let images = [makeImage(id: 1), makeImage(id: 2)]
        let plan = BatchTagToggle.plan(images: images, tagId: 10, imageTagIds: [1: [10], 2: [10]])
        XCTAssertFalse(plan.shouldAdd)
        XCTAssertEqual(plan.targets.map(\.id), [1, 2])
    }

    /// 別のタグが付いていても、対象タグの有無だけで判断する。
    func testOtherTagsDoNotAffectDecision() {
        let images = [makeImage(id: 1), makeImage(id: 2)]
        let plan = BatchTagToggle.plan(images: images, tagId: 10, imageTagIds: [1: [20, 30], 2: [20]])
        XCTAssertTrue(plan.shouldAdd)
        XCTAssertEqual(plan.targets.map(\.id), [1, 2])
    }

    func testEmptyInputIsNoOp() {
        let plan = BatchTagToggle.plan(images: [], tagId: 10, imageTagIds: [:])
        XCTAssertTrue(plan.isNoOp)
        XCTAssertEqual(plan.targets.count, 0)
    }

    func testSingleTaggedImageIsRemoval() {
        let images = [makeImage(id: 1)]
        let plan = BatchTagToggle.plan(images: images, tagId: 10, imageTagIds: [1: [10]])
        XCTAssertFalse(plan.shouldAdd)
        XCTAssertEqual(plan.targets.map(\.id), [1])
    }

    func testTargetsPreserveInputOrder() {
        let images = [makeImage(id: 3), makeImage(id: 1), makeImage(id: 2)]
        let plan = BatchTagToggle.plan(images: images, tagId: 10, imageTagIds: [:])
        XCTAssertEqual(plan.targets.map(\.id), [3, 1, 2])
    }
}
