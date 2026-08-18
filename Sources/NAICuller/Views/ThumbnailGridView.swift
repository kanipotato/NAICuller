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
            guard let collectionView else { return false }
            // 選択・起点・フォーカスの決定はAppKitに依存しない純粋ロジックとして
            // Core層のGridSelectionPlannerに切り出してある（過去に2回バグを踏んだ箇所）。
            guard let plan = GridSelectionPlanner.plan(
                imageIds: images.map(\.id),
                clickedIndex: indexPath.item,
                modifiers: Self.selectionModifiers(from: modifiers),
                currentSelection: Set(collectionView.selectionIndexPaths.map(\.item)),
                anchorImageId: selectionAnchorId
            ) else { return false }

            selectionAnchorId = plan.anchorImageId
            collectionView.selectionIndexPaths = Set(plan.selectedIndices.map { IndexPath(item: $0, section: 0) })
            syncSelection(collectionView)
            parent.appModel.focusedImageId = plan.focusedImageId
            return true
        }

        /// AppKitの修飾キーをCore層の表現へ落とす。Shift/Cmdの同時押しも
        /// そのまま両方立てて渡す（フォールバックの判断はPlanner側が持つ）。
        private static func selectionModifiers(from modifiers: NSEvent.ModifierFlags) -> GridSelectionModifiers {
            var result: GridSelectionModifiers = []
            if modifiers.contains(.shift) { result.insert(.shift) }
            if modifiers.contains(.command) { result.insert(.command) }
            return result
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
