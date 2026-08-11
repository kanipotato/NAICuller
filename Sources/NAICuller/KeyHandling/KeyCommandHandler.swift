import AppKit
import NAICullerCore

/// キーボード操作（矢印/F/G/1〜9）をアプリ全体で受け付けるハンドラ（詳細設計 1章）。
///
/// `NSEvent.addLocalMonitorForEvents`でアプリ内のキーイベントを横取りする。
/// macOS 13をターゲットにしているため、SwiftUIの`.onKeyPress`（macOS 14以降）は使えない。
/// テキストフィールド編集中（タグ自由入力・設定画面等）は素通りさせないと文字入力が
/// 壊れるため、ファーストレスポンダがテキスト編集系ビューのときはハンドリングをスキップする。
@MainActor
final class KeyCommandHandler {
    private weak var appModel: AppModel?
    private var monitor: Any?

    init(appModel: AppModel) {
        self.appModel = appModel
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.isEditingText(event) {
                return event
            }
            if self.handle(event) {
                return nil // イベントを消費（他へ伝播させない）
            }
            return event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    private func isEditingText(_ event: NSEvent) -> Bool {
        guard let responder = event.window?.firstResponder else { return false }
        if responder is NSText { return true } // フィールドエディタ（NSTextView）
        if responder is NSTextField { return true }
        return false
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let appModel else { return false }

        switch event.keyCode {
        case KeyCode.leftArrow, KeyCode.upArrow:
            moveFocus(by: -1, appModel: appModel)
            return true
        case KeyCode.rightArrow, KeyCode.downArrow:
            moveFocus(by: 1, appModel: appModel)
            return true
        case KeyCode.space:
            // Finderと同じ操作感（スペースキーでQuick Look）。実際に使ってみてのフィードバックで、
            // 画像を大きく見る手段が他アプリで開く以外に無かったため追加した。
            appModel.quickLookController.toggle()
            return true
        default:
            break
        }

        guard let characters = event.charactersIgnoringModifiers?.lowercased() else { return false }

        let targets = currentTargetImages(appModel)
        guard !targets.isEmpty else { return false }

        switch characters {
        case "f", "g":
            appModel.toggleTag(forKey: characters.uppercased(), on: targets)
            return true
        case "1", "2", "3", "4", "5", "6", "7", "8", "9":
            appModel.toggleTag(forKey: characters, on: targets)
            return true
        default:
            return false
        }
    }

    private func currentFocusedImage(_ appModel: AppModel) -> ImageRecord? {
        let list = appModel.filteredImages
        if let focusedId = appModel.focusedImageId, let image = list.first(where: { $0.id == focusedId }) {
            return image
        }
        return list.first
    }

    /// タグ付け操作の対象。複数選択中（グリッドでcmd/shift-クリック等）なら選択中の全画像、
    /// そうでなければフォーカス中の1枚（矢印キーでのプレビュー対象）を返す
    /// （実際に使ってみてのフィードバックを受けて、複数選択時の一括タグ付けに対応した）。
    private func currentTargetImages(_ appModel: AppModel) -> [ImageRecord] {
        if appModel.selectedImageIds.count > 1 {
            let list = appModel.filteredImages
            return list.filter { appModel.selectedImageIds.contains($0.id) }
        }
        return currentFocusedImage(appModel).map { [$0] } ?? []
    }

    /// 矢印キー：プレビュー（focusedImageId）を維持したまま前後の画像へ移動する。
    private func moveFocus(by delta: Int, appModel: AppModel) {
        let list = appModel.filteredImages
        guard !list.isEmpty else { return }
        let currentIndex = appModel.focusedImageId.flatMap { id in list.firstIndex(where: { $0.id == id }) } ?? 0
        let newIndex = min(max(currentIndex + delta, 0), list.count - 1)
        let newId = list[newIndex].id
        appModel.focusedImageId = newId
        appModel.selectedImageIds = [newId]
    }

    private enum KeyCode {
        static let leftArrow: UInt16 = 123
        static let rightArrow: UInt16 = 124
        static let downArrow: UInt16 = 125
        static let upArrow: UInt16 = 126
        static let space: UInt16 = 49
    }
}
