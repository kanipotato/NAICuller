import AppKit
import NAICullerCore

// サムネイルグリッドの右クリックメニュー。
//
// 元は`ThumbnailGridView.Coordinator`本体に、DataSource/Delegate/Prefetching/クリック選択/
// サムネイル読み込みと並んで直接書かれていた（Coordinatorだけで350行超）。メニューの構築と
// そのアクションハンドラは他の責務から一切参照されない独立した塊なので、extensionとして
// このファイルへまとめた。ここで使うヘルパー・アクション用の型もすべて同居させてあるため、
// `private`のままファイル内に閉じている。
extension ThumbnailGridView.Coordinator {
    // MARK: - 右クリックメニュー（タグ付け・お気に入り・削除対象・エクスポート）
    //
    // F/G/1-9キーのトグルも既存タグも「内部的にはすべて同一のタグ機構」（詳細設計1章）なので、
    // 既存タグ一覧をチェック可能なメニュー項目として並べるだけで、お気に入り・削除対象・
    // カスタムタグすべてを右クリックからも操作できる（新しいタグ付けロジックは追加していない、
    // 既存のtoggleTagをそのまま呼ぶだけ）。複数選択中に右クリックした場合は選択中の全画像が
    // 対象になる（実際に使ってみてのフィードバックを受けて対応）。

    /// クリックされた項目が現在の選択に含まれていなければ単独選択に切り替える（Finder同様の挙動）。
    /// 既に複数選択の一部としてクリックされた場合は、選択中の全画像が対象になる。
    func contextMenu(for indexPath: IndexPath) -> NSMenu? {
        guard indexPath.item < images.count, let collectionView else { return nil }
        let clickedImage = images[indexPath.item]
        if !collectionView.selectionIndexPaths.contains(indexPath) {
            // コードレビュー指摘の修正：以前はここで選択の切り替えだけを独自に行っており、
            // `handleClick`が更新する`selectionAnchorId`（Shift+クリックの起点）が
            // 素通りされていた。右クリックで単独選択に切り替えた直後にShift+クリックすると、
            // 今right-clickした項目ではなく古い起点から範囲選択されてしまう不具合があった。
            // 無修飾クリックと同じ経路（`handleClick`）に一本化して起点も正しく更新する。
            handleClick(at: indexPath, modifiers: [])
        }
        let selectedIds = parent.appModel.selectedImageIds
        let targets = selectedIds.count > 1 ? images.filter { selectedIds.contains($0.id) } : [clickedImage]
        return buildMenu(for: targets)
    }

    private func buildMenu(for targets: [ImageRecord]) -> NSMenu {
        let menu = NSMenu()
        let appModel = parent.appModel

        // Quick Look・固定表示はどちらも1枚を表示する仕組みなので、複数選択時は出さない。
        if targets.count == 1 {
            let quickLookItem = NSMenuItem(title: "大きく表示（Quick Look）", action: #selector(showQuickLookFromMenu(_:)), keyEquivalent: "")
            quickLookItem.target = self
            menu.addItem(quickLookItem)

            // 選択に追従するQuick Lookと違い、比較用にこの1枚を選択に連動させず
            // 別ウィンドウで開いたままにしておきたいという要望から追加。
            let pinnedItem = NSMenuItem(title: "この画像を固定表示", action: #selector(showPinnedPreviewFromMenu(_:)), keyEquivalent: "")
            pinnedItem.target = self
            pinnedItem.representedObject = targets[0].id
            menu.addItem(pinnedItem)

            menu.addItem(.separator())
        }

        // お気に入り(F)・削除対象(G)・1〜9キー割当済みタグを先に、キー順で並べる。
        let sortedTags = appModel.tags.sorted { lhs, rhs in
            let lKey = lhs.keyBinding ?? "~"
            let rKey = rhs.keyBinding ?? "~"
            return lKey == rKey ? lhs.name < rhs.name : lKey < rKey
        }
        for tag in sortedTags {
            let title = tag.keyBinding.map { "\(tag.name)（\($0)）" } ?? tag.name
            let item = NSMenuItem(title: title, action: #selector(toggleTagFromMenu(_:)), keyEquivalent: "")
            item.target = self
            // 複数選択時は一部だけタグ付きなら`.mixed`（中間状態のダッシュ表示）にする。
            let taggedCount = targets.filter { appModel.imageTagIds[$0.id]?.contains(tag.id) ?? false }.count
            item.state = taggedCount == targets.count ? .on : (taggedCount == 0 ? .off : .mixed)
            item.representedObject = MenuTagAction(imageIds: targets.map(\.id), tagId: tag.id)
            menu.addItem(item)
        }
        if sortedTags.isEmpty {
            menu.addItem(NSMenuItem(title: "タグがまだ無いよ", action: nil, keyEquivalent: ""))
        }

        menu.addItem(.separator())
        // JSON（パス・プロンプト等のメタデータ）／画像ファイル本体コピーの2択サブメニュー。
        // ツールバーのエクスポートボタン（SwiftUIのセグメントピッカー）と同じ2モードだが、
        // NSMenuにはポップオーバーを出せないのでサブメニュー形式にしてある
        // （レビュー指摘の修正：ツールバー側だけ画像ファイルモードを追加し、右クリック側を
        // 直し忘れていた。同じ「エクスポート」という名前の入口が2つあるのに挙動が違うのは
        // 混乱の元なので、必ず両方揃える）。
        let exportTitle = targets.count > 1 ? "選択中の\(targets.count)件をエクスポート" : "この画像をエクスポート"
        let exportMenuItem = NSMenuItem(title: exportTitle, action: nil, keyEquivalent: "")
        let exportSubmenu = NSMenu()
        let exportJSONItem = NSMenuItem(title: "JSON（パス・プロンプト）...", action: #selector(exportImagesFromMenu(_:)), keyEquivalent: "")
        exportJSONItem.target = self
        exportJSONItem.representedObject = targets.map(\.id)
        exportSubmenu.addItem(exportJSONItem)
        let exportFilesItem = NSMenuItem(title: "画像ファイルをコピー...", action: #selector(exportImageFilesFromMenu(_:)), keyEquivalent: "")
        exportFilesItem.target = self
        exportFilesItem.representedObject = targets.map(\.id)
        exportSubmenu.addItem(exportFilesItem)
        exportMenuItem.submenu = exportSubmenu
        menu.addItem(exportMenuItem)

        // 「削除対象」タグが付いた画像だけを対象にした移動（ゴミ箱／バックアップフォルダ）。
        // ツールバーの「削除」メニューと同じAppModelロジックをそのまま呼ぶ（対象の絞り込みは
        // AppModel側の`selectedMarkedImages()`が既に担っており、ここで右クリック対象を絞り込む
        // 必要は無い。右クリック時点で選択が現在のtargetsと一致するよう`contextMenu(for:)`が
        // 事前に同期している）。実際に使ってみてのフィードバックで、ツールバーからだけでなく
        // 右クリックからもすぐ移動したいという要望があり追加した。
        let moveTitle = targets.count > 1 ? "選択中の削除対象\(targets.count)件を移動" : "削除対象を移動"
        let moveMenuItem = NSMenuItem(title: moveTitle, action: nil, keyEquivalent: "")
        let moveSubmenu = NSMenu()
        let trashItem = NSMenuItem(title: "ゴミ箱へ", action: #selector(moveMarkedToTrashFromMenu(_:)), keyEquivalent: "")
        trashItem.target = self
        moveSubmenu.addItem(trashItem)
        let backupItem = NSMenuItem(title: "バックアップフォルダへ...", action: #selector(moveMarkedToBackupFromMenu(_:)), keyEquivalent: "")
        backupItem.target = self
        moveSubmenu.addItem(backupItem)
        moveMenuItem.submenu = moveSubmenu
        menu.addItem(moveMenuItem)

        // bg-splitter(自分専用の背景透過+シート分割ツール)が見つかっている時だけ出す。
        // 他のNAICullerユーザーの環境ではbgSplitterAvailableがfalseのままなので
        // このセクション自体が表示されない（グレーアウトではなく非表示にしている）。
        if appModel.bgSplitter.isAvailable {
            menu.addItem(.separator())
            let imageIds = targets.map(\.id)

            let removeBgTitle = targets.count > 1 ? "選択中の\(targets.count)件を背景透過" : "背景透過"
            let removeBgItem = NSMenuItem(title: removeBgTitle, action: #selector(removeBackgroundFromMenu(_:)), keyEquivalent: "")
            removeBgItem.target = self
            removeBgItem.representedObject = BgSplitterMenuAction(imageIds: imageIds, model: nil)
            menu.addItem(removeBgItem)
            menu.addItem(bgSplitterModelSubmenuItem(
                title: "背景透過（モデルを指定）",
                imageIds: imageIds,
                action: #selector(removeBackgroundFromMenu(_:))
            ))

            let splitTitle = targets.count > 1 ? "選択中の\(targets.count)件をシート分割" : "シート分割(グリッド自動検出)"
            let splitItem = NSMenuItem(title: splitTitle, action: #selector(splitSheetFromMenu(_:)), keyEquivalent: "")
            splitItem.target = self
            splitItem.representedObject = BgSplitterMenuAction(imageIds: imageIds, model: nil)
            menu.addItem(splitItem)
            menu.addItem(bgSplitterModelSubmenuItem(
                title: "シート分割（モデルを指定）",
                imageIds: imageIds,
                action: #selector(splitSheetFromMenu(_:))
            ))

            // このセル自体が分割済みファイル（<元名>_r{行}_c{列}.png）らしい時だけ、
            // 「やり直す」を出す。複数選択だと元シートが揃わない可能性があるので単一選択限定。
            if targets.count == 1, BgSplitterService.splitCellStem(fromFileName: targets[0].url.lastPathComponent) != nil {
                let redoItem = NSMenuItem(title: "この分割をやり直す（余白調整）...", action: #selector(redoSplitFromMenu(_:)), keyEquivalent: "")
                redoItem.target = self
                redoItem.representedObject = targets[0].id
                menu.addItem(redoItem)
            }
        }
        return menu
    }

    /// 「モデルを指定」サブメニュー（u2net/isnet-anime等を並べる）を組み立てる。
    /// 背景透過・シート分割の両方で同じ構造なので共通化している。
    private func bgSplitterModelSubmenuItem(title: String, imageIds: [Int64], action: Selector) -> NSMenuItem {
        let submenu = NSMenu()
        for model in BgSplitterModel.all {
            let item = NSMenuItem(title: model.displayName, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = BgSplitterMenuAction(imageIds: imageIds, model: model.id)
            item.toolTip = model.usageHint
            submenu.addItem(item)
        }
        let submenuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        submenuItem.submenu = submenu
        return submenuItem
    }

    private struct MenuTagAction {
        let imageIds: [Int64]
        let tagId: Int64
    }

    /// 背景透過/シート分割メニューのrepresentedObject。`model`がnilならAppModel側の
    /// デフォルトモデル（Settings画面で設定）を使う。「モデルを指定」サブメニューから
    /// 呼ばれた時だけ具体的なmodel idが入る。
    private struct BgSplitterMenuAction {
        let imageIds: [Int64]
        let model: String?
    }

    @objc private func showQuickLookFromMenu(_ sender: NSMenuItem) {
        // contextMenu(for:)側で右クリック時点のfocusedImageIdは既に更新済みなので、
        // ここではトグルを呼ぶだけでよい。
        parent.appModel.quickLookController.toggle()
    }

    @objc private func showPinnedPreviewFromMenu(_ sender: NSMenuItem) {
        guard let imageId = sender.representedObject as? Int64,
              let image = images.first(where: { $0.id == imageId }) else { return }
        parent.appModel.showPinnedPreview(for: image)
    }

    @objc private func toggleTagFromMenu(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? MenuTagAction else { return }
        let targetImages = images.filter { action.imageIds.contains($0.id) }
        guard !targetImages.isEmpty else { return }
        parent.appModel.toggleTag(tagId: action.tagId, on: targetImages)
    }

    @objc private func exportImagesFromMenu(_ sender: NSMenuItem) {
        guard let imageIds = sender.representedObject as? [Int64] else { return }
        let targetImages = images.filter { imageIds.contains($0.id) }
        guard !targetImages.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ExportService.defaultFileName()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        parent.appModel.exportImages(targetImages, fields: ExportFieldKind.allCases, to: url)
    }

    @objc private func exportImageFilesFromMenu(_ sender: NSMenuItem) {
        guard let imageIds = sender.representedObject as? [Int64] else { return }
        let targetImages = images.filter { imageIds.contains($0.id) }
        guard !targetImages.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "選択"
        panel.message = "コピー先のフォルダを選んでね"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        parent.appModel.copyImagesToFolder(targetImages, to: url)
    }

    @objc private func moveMarkedToTrashFromMenu(_ sender: NSMenuItem) {
        parent.appModel.requestMoveSelectedMarkedImages(to: .trash)
    }

    @objc private func moveMarkedToBackupFromMenu(_ sender: NSMenuItem) {
        parent.appModel.chooseBackupFolderAndRequestMove(scope: .selected)
    }

    @objc private func removeBackgroundFromMenu(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? BgSplitterMenuAction else { return }
        let targetImages = images.filter { action.imageIds.contains($0.id) }
        guard !targetImages.isEmpty else { return }
        parent.appModel.bgSplitter.removeBackground(for: targetImages, model: action.model)
    }

    @objc private func splitSheetFromMenu(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? BgSplitterMenuAction else { return }
        let targetImages = images.filter { action.imageIds.contains($0.id) }
        guard !targetImages.isEmpty else { return }
        parent.appModel.bgSplitter.splitSheet(for: targetImages, model: action.model)
    }

    @objc private func redoSplitFromMenu(_ sender: NSMenuItem) {
        guard let imageId = sender.representedObject as? Int64,
              let image = images.first(where: { $0.id == imageId }) else { return }
        parent.appModel.bgSplitter.requestSplitRedo(for: image)
    }
}
