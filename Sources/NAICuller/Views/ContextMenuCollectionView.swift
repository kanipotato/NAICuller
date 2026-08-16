import AppKit

/// 右クリックメニューと、Finder同様の選択規則（無修飾クリック=単独選択・Cmd+クリック=トグル・
/// Shift+クリック=範囲選択）に対応するための`NSCollectionView`サブクラス。
///
/// `NSCollectionView`は`allowsMultipleSelection`を有効にしてもCmd+クリックのトグルにしか
/// 標準対応しておらず、Shift+クリックによる範囲選択は自前実装が必要（`NSTableView`と違い
/// 既定の`mouseDown`処理には範囲選択のロジックが含まれていない、既知の制限）。そのため
/// `mouseDown`自体を乗っ取り、クリックされた項目と修飾キーからCoordinatorに選択計算を
/// 委譲する。
final class ContextMenuCollectionView: NSCollectionView {
    weak var menuCoordinator: ThumbnailGridView.Coordinator?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point) else { return nil }
        return menuCoordinator?.contextMenu(for: indexPath)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point),
              menuCoordinator?.handleClick(at: indexPath, modifiers: event.modifierFlags) == true else {
            // 項目の無い領域（余白）のクリックは既定の挙動（全選択解除・ラバーバンド選択）に任せる。
            super.mouseDown(with: event)
            return
        }
        // 既定のmouseDownを呼ばない分、ファーストレスポンダへの昇格は自分で行う。
        window?.makeFirstResponder(self)
    }
}
