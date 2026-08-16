import XCTest
@testable import NAICullerCore

/// サムネイルグリッドのクリック選択（`ThumbnailGridView.Coordinator.handleClick`から切り出したもの）のテスト。
/// 過去に踏んだ2つのバグ（起点をIDで持つ / Cmd解除時のフォーカス移譲）を明示的に固定する。
final class GridSelectionPlannerTests: XCTestCase {
    private let ids: [Int64] = [10, 20, 30, 40, 50]

    private func plan(
        _ clickedIndex: Int,
        _ modifiers: GridSelectionModifiers = [],
        selection: Set<Int> = [],
        anchor: Int64? = nil,
        imageIds: [Int64]? = nil
    ) -> GridSelectionPlan? {
        GridSelectionPlanner.plan(
            imageIds: imageIds ?? ids,
            clickedIndex: clickedIndex,
            modifiers: modifiers,
            currentSelection: selection,
            anchorImageId: anchor
        )
    }

    // MARK: - 無修飾クリック

    func testPlainClickReplacesSelectionAndSetsAnchor() {
        let result = plan(2, [], selection: [0, 1])
        XCTAssertEqual(result?.selectedIndices, [2])
        XCTAssertEqual(result?.anchorImageId, 30)
        XCTAssertEqual(result?.focusedImageId, 30)
    }

    func testOutOfRangeClickIsIgnored() {
        XCTAssertNil(plan(99))
        XCTAssertNil(plan(-1))
        XCTAssertNil(plan(0, imageIds: []))
    }

    // MARK: - Cmd+クリック（トグル）

    func testCommandClickAddsToSelection() {
        let result = plan(3, [.command], selection: [0])
        XCTAssertEqual(result?.selectedIndices, [0, 3])
        XCTAssertEqual(result?.anchorImageId, 40)
        XCTAssertEqual(result?.focusedImageId, 40)
    }

    /// バグ2の回帰テスト：クリックした項目自体を選択解除したとき、フォーカスを
    /// そこに残すと非選択の画像にF/Gキーのタグ付けが効いてしまう。
    func testCommandClickDeselectingHandsFocusToFirstRemaining() {
        let result = plan(3, [.command], selection: [1, 3])
        XCTAssertEqual(result?.selectedIndices, [1])
        XCTAssertEqual(result?.focusedImageId, 20, "解除した項目ではなく残った選択の先頭にフォーカスを譲るべき")
    }

    func testCommandClickDeselectingLastItemClearsFocus() {
        let result = plan(3, [.command], selection: [3])
        XCTAssertEqual(result?.selectedIndices, [])
        XCTAssertNil(result?.focusedImageId)
    }

    // MARK: - Shift+クリック（範囲選択）

    func testShiftClickSelectsRangeFromAnchor() {
        let result = plan(4, [.shift], selection: [1], anchor: 20)
        XCTAssertEqual(result?.selectedIndices, [1, 2, 3, 4])
        XCTAssertEqual(result?.focusedImageId, 50)
    }

    func testShiftClickWorksBackwards() {
        let result = plan(0, [.shift], selection: [3], anchor: 40)
        XCTAssertEqual(result?.selectedIndices, [0, 1, 2, 3])
    }

    /// 連続Shift+クリックで起点が動かないこと（動くと範囲が伸び縮みではなく累積してしまう）。
    func testShiftClickKeepsAnchorFixed() {
        let first = plan(4, [.shift], selection: [1], anchor: 20)
        XCTAssertEqual(first?.anchorImageId, 20)
        let second = plan(2, [.shift], selection: first!.selectedIndices, anchor: first!.anchorImageId)
        XCTAssertEqual(second?.selectedIndices, [1, 2], "起点が動くと範囲が正しく縮まらない")
        XCTAssertEqual(second?.anchorImageId, 20)
    }

    /// バグ1の回帰テスト：起点を位置ではなくIDで持つので、並び替えで配列順が変わっても
    /// 同じ画像が起点であり続ける。
    func testAnchorFollowsImageIdAcrossReordering() {
        // 元の並び [10,20,30,40,50] で 20 を起点にした後、逆順に並び替えた状態でクリックする。
        let reordered: [Int64] = [50, 40, 30, 20, 10]
        // 逆順配列で 20 は index 3。index 1(=40) をクリックすると 1...3 が選ばれるはず。
        let result = plan(1, [.shift], selection: [], anchor: 20, imageIds: reordered)
        XCTAssertEqual(result?.selectedIndices, [1, 2, 3])
        XCTAssertEqual(result?.focusedImageId, 40)
    }

    /// 起点が絞り込みで画面から消えている場合は範囲選択にならず、単独選択に落ちる。
    func testShiftClickWithUnresolvableAnchorFallsBackToSingle() {
        let result = plan(2, [.shift], selection: [0], anchor: 999)
        XCTAssertEqual(result?.selectedIndices, [2])
        XCTAssertEqual(result?.anchorImageId, 30)
    }

    func testShiftClickWithNoAnchorFallsBackToSingle() {
        let result = plan(2, [.shift], selection: [0], anchor: nil)
        XCTAssertEqual(result?.selectedIndices, [2])
    }

    /// Shift+Cmd同時押しで起点が解決できないときは、Cmdのトグルへフォールバックする
    /// （元実装のif-else連鎖の順序。修飾キーを排他enumに潰すと再現できない分岐）。
    func testShiftAndCommandWithUnresolvableAnchorFallsBackToCommandToggle() {
        let result = plan(2, [.shift, .command], selection: [0], anchor: nil)
        XCTAssertEqual(result?.selectedIndices, [0, 2], "Cmdのトグル挙動になるべき")
    }

    /// 起点が解決できるならShift+Cmdでも範囲選択が優先される。
    func testShiftAndCommandWithResolvableAnchorUsesRange() {
        let result = plan(3, [.shift, .command], selection: [0], anchor: 20)
        XCTAssertEqual(result?.selectedIndices, [1, 2, 3])
    }

    func testShiftClickOnAnchorItselfSelectsOnlyThatItem() {
        let result = plan(1, [.shift], selection: [1, 2, 3], anchor: 20)
        XCTAssertEqual(result?.selectedIndices, [1])
    }
}
