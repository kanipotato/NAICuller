import Foundation

/// クリック時に押されていた修飾キー（Finderの3規則に対応）。
/// AppKitの`NSEvent.ModifierFlags`をCore層に持ち込まないための最小の表現。
///
/// 排他のenumではなくOptionSetにしているのは、「Shift+Cmd同時押しで、かつ起点が
/// 現在の配列内に見つからない」ときに元実装がCmd（トグル）へフォールバックする
/// ためで、片方だけの状態に潰すとこの分岐を再現できないため。
public struct GridSelectionModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Cmd：クリックした1件の選択状態だけをトグルする。
    public static let command = GridSelectionModifiers(rawValue: 1 << 0)
    /// Shift：起点からクリック位置までを範囲選択する。
    public static let shift = GridSelectionModifiers(rawValue: 1 << 1)
}

/// クリック1回で決まる、選択・起点・フォーカスの新しい状態。
public struct GridSelectionPlan: Equatable, Sendable {
    /// 新しい選択（`images`配列上の位置）。
    public let selectedIndices: Set<Int>
    /// 次のShift+クリックの起点。**位置ではなく画像ID**で持つ。
    public let anchorImageId: Int64?
    /// 新しいフォーカス画像（キーボードのタグ付けが効く対象）。
    public let focusedImageId: Int64?

    public init(selectedIndices: Set<Int>, anchorImageId: Int64?, focusedImageId: Int64?) {
        self.selectedIndices = selectedIndices
        self.anchorImageId = anchorImageId
        self.focusedImageId = focusedImageId
    }
}

/// サムネイルグリッドのクリック選択（Finder同様の無修飾/Cmd/Shiftの3規則）の決定部分。
///
/// 元は`ThumbnailGridView.Coordinator.handleClick`の中でAppKitの
/// `collectionView.selectionIndexPaths`の読み書きと混ざっていた。この決定部分だけは
/// AppKitに依存せず純粋関数にできるうえ、過去に2回バグを踏んでいるのにテストが無かったため
/// 切り出した。
///
/// 踏んだバグ:
/// 1. Shift+クリックの起点を`IndexPath`（配列上の位置）で保持していたため、選択後に
///    ソート順を変えると同じ画像でも位置がずれ、全く無関係な範囲が選ばれた。
///    → 起点は画像IDで持ち、毎回現在の配列から位置を引き直す。
/// 2. Cmd+クリックでクリックした項目自体を選択解除したとき、フォーカスをその項目のままに
///    していたため、非選択（＝見た目上外れている）画像にF/Gキーのタグ付けが効いてしまった。
///    → 解除された場合は残っている選択の先頭へフォーカスを譲る。
public enum GridSelectionPlanner {
    /// - Parameters:
    ///   - imageIds: 現在グリッドに並んでいる画像IDを表示順に並べたもの。
    ///   - clickedIndex: クリックされた位置。範囲外なら`nil`を返す（呼び出し側は何もしない）。
    ///   - currentSelection: クリック直前の選択（位置）。
    ///   - anchorImageId: 直前までのShift+クリック起点（画像ID）。
    /// - Returns: 新しい状態。`clickedIndex`が範囲外なら`nil`。
    public static func plan(
        imageIds: [Int64],
        clickedIndex: Int,
        modifiers: GridSelectionModifiers,
        currentSelection: Set<Int>,
        anchorImageId: Int64?
    ) -> GridSelectionPlan? {
        guard imageIds.indices.contains(clickedIndex) else { return nil }
        let clickedId = imageIds[clickedIndex]

        let newSelection: Set<Int>
        let newAnchorId: Int64?

        // Shiftは「起点が現在の配列内に見つかるとき」だけ範囲選択になる。起点が未設定、
        // または並び替え・絞り込みで画面から消えている場合は下の分岐へ落ちる
        // （Cmdも押されていればトグル、押されていなければ単独選択。元実装と同じ順序）。
        if modifiers.contains(.shift),
           let anchorId = anchorImageId,
           let anchorIndex = imageIds.firstIndex(of: anchorId) {
            let lower = min(anchorIndex, clickedIndex)
            let upper = max(anchorIndex, clickedIndex)
            newSelection = Set(lower...upper)
            // 起点は動かさない：連続してShift+クリックしても常に同じ起点からの範囲になる。
            newAnchorId = anchorId
        } else if modifiers.contains(.command) {
            var toggled = currentSelection
            if toggled.contains(clickedIndex) {
                toggled.remove(clickedIndex)
            } else {
                toggled.insert(clickedIndex)
            }
            newSelection = toggled
            newAnchorId = clickedId
        } else {
            newSelection = [clickedIndex]
            newAnchorId = clickedId
        }

        let focusedImageId: Int64?
        if newSelection.contains(clickedIndex) {
            focusedImageId = clickedId
        } else if let firstRemaining = newSelection.sorted().first, imageIds.indices.contains(firstRemaining) {
            focusedImageId = imageIds[firstRemaining]
        } else {
            focusedImageId = nil
        }

        return GridSelectionPlan(
            selectedIndices: newSelection,
            anchorImageId: newAnchorId,
            focusedImageId: focusedImageId
        )
    }
}
