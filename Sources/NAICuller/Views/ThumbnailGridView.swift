import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NAICullerCore

/// サムネイルの仮想スクロールグリッド。`NSViewRepresentable`で`NSCollectionView`を包む
/// （詳細設計 0章：1万枚超は仮想スクロール前提。SwiftUIの`LazyVGrid`ではなくAppKitを直接使う）。
///
/// 表示直前の遅延生成・先読みは`NSCollectionViewPrefetching`（画面に入る直前の範囲を
/// AppKitが教えてくれる標準APIで、iOSのUICollectionViewDataSourcePrefetchingと同じ設計）を使う。
/// 生成そのものはバックグラウンドキューで行い、メインスレッドをブロックしない。
struct ThumbnailGridView: NSViewRepresentable {
    @EnvironmentObject var appModel: AppModel

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

        let collectionView = ContextMenuCollectionView()
        collectionView.menuCoordinator = context.coordinator
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(ThumbnailItem.self, forItemWithIdentifier: ThumbnailItem.identifier)
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.prefetchDataSource = context.coordinator

        let scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        context.coordinator.collectionView = collectionView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let collectionView = coordinator.collectionView else { return }

        if let flowLayout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout {
            let side = appModel.thumbnailSize.maxPixelSize
            flowLayout.itemSize = NSSize(width: side, height: side)
        }

        let newImages = appModel.filteredImages
        if newImages.map(\.id) != coordinator.images.map(\.id) {
            coordinator.images = newImages
            collectionView.reloadData()
        } else {
            coordinator.images = newImages
        }

        // Coordinator側(AppKit発)がappModelへ選択を書き込んだ直後の折り返しのupdateNSViewでは、
        // ここでの再代入をスキップする（Shift+クリックの範囲選択が効かない不具合の修正）。
        // NSCollectionViewは複数選択の際、range選択の「起点」を内部的に保持しているが、
        // didSelectItemsAt経由でappModel.selectedImageIdsを更新→SwiftUIがそれを検知して
        // updateNSViewを呼び直す→ここでselectionIndexPathsに（今の内容と同じでも）再代入する、
        // という往復が同じイベント処理の流れの中で起こると、AppKit側の内部状態（起点）が
        // 途中でリセットされ、次のShift+クリックが単発クリックとして扱われてしまっていた。
        if coordinator.suppressNextSelectionSync {
            coordinator.suppressNextSelectionSync = false
        } else {
            let desiredIndexPaths = Set(appModel.selectedImageIds.compactMap { id -> IndexPath? in
                guard let index = newImages.firstIndex(where: { $0.id == id }) else { return nil }
                return IndexPath(item: index, section: 0)
            })
            if collectionView.selectionIndexPaths != desiredIndexPaths {
                collectionView.selectionIndexPaths = desiredIndexPaths
            }
        }
    }

    // AppKitのNSCollectionViewDataSource/Delegate/Prefetching各メソッドは`@MainActor`で宣言されている
    // （常にメインスレッドから呼ばれる契約）。Coordinator自体を`@MainActor`にすることで、
    // AppModel（`@MainActor`）のプロパティへ同期的に安全にアクセスできるようにする。
    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewPrefetching {
        var parent: ThumbnailGridView
        weak var collectionView: NSCollectionView?
        var images: [ImageRecord] = []
        /// `syncSelection`でappModelへ書き込んだ直後、その変化を検知して呼ばれる次の
        /// `updateNSView`が選択をappModel側から再代入しないようにするフラグ（Shift+クリックの
        /// 範囲選択が壊れる不具合の修正）。
        var suppressNextSelectionSync = false
        /// Shift+クリックで範囲選択する際の起点（画像ID）。Finderと同じく、Shiftを押さない
        /// 通常クリック・Cmd+クリックのたびに更新し、以降のShift+クリックは常にこの起点からの
        /// 範囲になる。IndexPathではなくIDで持つ理由はhandleClick内のコメント参照。
        private var selectionAnchorId: Int64?
        private static let placeholder = Coordinator.makePlaceholderImage()

        init(_ parent: ThumbnailGridView) {
            self.parent = parent
        }

        // MARK: - NSCollectionViewDataSource

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            images.count
        }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            guard let item = collectionView.makeItem(withIdentifier: ThumbnailItem.identifier, for: indexPath) as? ThumbnailItem else {
                return NSCollectionViewItem()
            }
            guard indexPath.item < images.count else { return item }
            let image = images[indexPath.item]
            loadThumbnail(for: image, into: item, indexPath: indexPath)
            return item
        }

        // MARK: - NSCollectionViewPrefetching（画面に入る直前の範囲の先読み。詳細設計 0章）

        func collectionView(_ collectionView: NSCollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            let thumbnailService = parent.appModel.thumbnailService!
            let size = parent.appModel.thumbnailSize
            let targets = indexPaths.compactMap { $0.item < images.count ? images[$0.item] : nil }
            DispatchQueue.global(qos: .utility).async {
                for image in targets {
                    guard thumbnailService.cachedData(imageId: image.id) == nil else { continue }
                    do {
                        try thumbnailService.generate(imageId: image.id, sourcePath: image.path, size: size)
                    } catch {
                        // 詳細設計 5章：サムネイル生成失敗はログに記録してスキャン/表示自体は継続する。
                        NSLog("[NAICuller] サムネイル先読み生成に失敗: \(image.path): \(error)")
                    }
                }
            }
        }

        func collectionView(_ collectionView: NSCollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
            // 生成処理自体を安全に中断する仕組みは持たないため何もしない
            // （キャッシュ済みなら次回即座に使われるので無駄にはならない）。
        }

        // MARK: - NSCollectionViewDelegate（選択状態の同期）

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            syncSelection(collectionView)
            if let firstIndex = indexPaths.map(\.item).sorted().first, firstIndex < images.count {
                parent.appModel.focusedImageId = images[firstIndex].id
            }
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            syncSelection(collectionView)
        }

        private func syncSelection(_ collectionView: NSCollectionView) {
            let ids = collectionView.selectionIndexPaths.compactMap { $0.item < images.count ? images[$0.item].id : nil }
            suppressNextSelectionSync = true
            parent.appModel.selectedImageIds = Set(ids)
        }

        // MARK: - クリック選択（Finder同様の無修飾/Cmd/Shiftの3規則。`ContextMenuCollectionView`から呼ばれる）

        /// `collectionView.selectionIndexPaths`への代入は`didSelectItemsAt`等のデリゲート通知を
        /// 発生させない仕様のため、ここで選択の計算・反映・appModelへの同期まで全て行う。
        ///
        /// 起点は`IndexPath`（配列上の位置）ではなく画像IDで持ち、Shift+クリックのたびに
        /// `images`配列内での現在位置を引き直して範囲を計算する。ソート順を変更すると
        /// 同じ画像でも配列内の位置がずれるため、位置をそのまま起点にすると選択後に
        /// ソート順を変えたときに全く無関係な範囲を選んでしまう（実際に使ってみての
        /// フィードバックを受けて検証し、位置ベースからID解決ベースに変更した）。
        @discardableResult
        func handleClick(at indexPath: IndexPath, modifiers: NSEvent.ModifierFlags) -> Bool {
            guard let collectionView, indexPath.item < images.count else { return false }
            let clickedId = images[indexPath.item].id

            var newSelection: Set<IndexPath>
            if modifiers.contains(.shift),
               let anchorId = selectionAnchorId,
               let anchorIndex = images.firstIndex(where: { $0.id == anchorId }) {
                let lower = min(anchorIndex, indexPath.item)
                let upper = max(anchorIndex, indexPath.item)
                newSelection = Set((lower...upper).map { IndexPath(item: $0, section: 0) })
                // 起点は動かさない：連続してShift+クリックしても常に同じ起点からの範囲になる。
            } else if modifiers.contains(.command) {
                newSelection = collectionView.selectionIndexPaths
                if newSelection.contains(indexPath) {
                    newSelection.remove(indexPath)
                } else {
                    newSelection.insert(indexPath)
                }
                selectionAnchorId = clickedId
            } else {
                newSelection = [indexPath]
                selectionAnchorId = clickedId
            }

            collectionView.selectionIndexPaths = newSelection
            syncSelection(collectionView)
            // コードレビュー指摘の修正：Cmd+クリックでクリックした項目自体を選択解除した場合に
            // それでも`focusedImageId`をクリック項目のままにしていたため、見えなくなった
            // （非選択状態の）画像にF/Gキーのタグ付けが効いてしまうバグがあった。
            // 選択解除された場合は、残っている選択の先頭（無ければnil）にフォーカスを譲る。
            if newSelection.contains(indexPath) {
                parent.appModel.focusedImageId = clickedId
            } else if let firstRemaining = newSelection.map(\.item).sorted().first, firstRemaining < images.count {
                parent.appModel.focusedImageId = images[firstRemaining].id
            } else {
                parent.appModel.focusedImageId = nil
            }
            return true
        }

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
            let exportTitle = targets.count > 1 ? "選択中の\(targets.count)件をエクスポート..." : "この画像をエクスポート..."
            let exportItem = NSMenuItem(title: exportTitle, action: #selector(exportImagesFromMenu(_:)), keyEquivalent: "")
            exportItem.target = self
            exportItem.representedObject = targets.map(\.id)
            menu.addItem(exportItem)

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

        // MARK: - サムネイル読み込み（表示直前の遅延生成。詳細設計 0章）

        private func loadThumbnail(for image: ImageRecord, into item: ThumbnailItem, indexPath: IndexPath) {
            let thumbnailService = parent.appModel.thumbnailService!
            let imageId = image.id

            if let cached = thumbnailService.cachedData(imageId: imageId) {
                item.configure(imageId: imageId, data: cached, placeholder: Self.placeholder)
                return
            }

            item.configure(imageId: imageId, data: nil, placeholder: Self.placeholder)
            let path = image.path
            let size = parent.appModel.thumbnailSize
            DispatchQueue.global(qos: .userInitiated).async { [weak self, weak collectionView = self.collectionView] in
                let data = try? thumbnailService.generate(imageId: imageId, sourcePath: path, size: size)
                guard let data else {
                    NSLog("[NAICuller] サムネイル生成に失敗（プレースホルダーのまま表示を継続）: \(path)")
                    return
                }
                DispatchQueue.main.async {
                    guard let collectionView, self != nil else { return }
                    guard let currentItem = collectionView.item(at: indexPath) as? ThumbnailItem else { return }
                    currentItem.applyLoadedData(data, forImageId: imageId)
                }
            }
        }

        private static func makePlaceholderImage() -> NSImage {
            let size = NSSize(width: 64, height: 64)
            let image = NSImage(size: size)
            image.lockFocus()
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
            image.unlockFocus()
            return image
        }
    }
}

/// 右クリックメニュー対応のための`NSCollectionView`サブクラス。`menu(for:)`をオーバーライドして
/// クリック位置からIndexPathを求め、Coordinatorに動的メニュー構築を委譲する
/// （`NSCollectionView`には項目ごとのコンテキストメニューを組み立てる標準デリゲートが無いため）。
/// 右クリックメニューと、Finder同様の選択規則（無修飾クリック=単独選択・Cmd+クリック=トグル・
/// Shift+クリック=範囲選択）に対応するための`NSCollectionView`サブクラス。
///
/// `NSCollectionView`は`allowsMultipleSelection`を有効にしてもCmd+クリックのトグルにしか
/// 標準対応しておらず、Shift+クリックによる範囲選択は自前実装が必要（`NSTableView`と違い
/// 既定の`mouseDown`処理には範囲選択のロジックが含まれていない、既知の制限）。そのため
/// `mouseDown`自体を乗っ取り、クリックされた項目と修飾キーからCoordinatorに選択計算を
/// 委譲する。
private final class ContextMenuCollectionView: NSCollectionView {
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

/// グリッドの1セル。壊れたPNG等でサムネイル生成に失敗した場合は`placeholder`のまま表示を継続する
/// （詳細設計 5章）。
final class ThumbnailItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ThumbnailItem")

    private let thumbnailImageView = NSImageView()
    private(set) var currentImageId: Int64?

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 4

        thumbnailImageView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailImageView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(thumbnailImageView)
        NSLayoutConstraint.activate([
            thumbnailImageView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            thumbnailImageView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            thumbnailImageView.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            thumbnailImageView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2)
        ])
        view = container
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.borderWidth = isSelected ? 3 : 0
            view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnailImageView.image = nil
        currentImageId = nil
    }

    func configure(imageId: Int64, data: Data?, placeholder: NSImage) {
        currentImageId = imageId
        if let data, let image = NSImage(data: data) {
            thumbnailImageView.image = image
        } else {
            thumbnailImageView.image = placeholder
        }
    }

    /// バックグラウンドで生成が完了した後の反映。セルが別画像に再利用済みなら無視する。
    func applyLoadedData(_ data: Data, forImageId imageId: Int64) {
        guard currentImageId == imageId else { return }
        guard let image = NSImage(data: data) else { return }
        thumbnailImageView.image = image
    }
}
