import SwiftUI
import AppKit
import NovelAIViewerCore

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

        let collectionView = NSCollectionView()
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

        let desiredIndexPaths = Set(appModel.selectedImageIds.compactMap { id -> IndexPath? in
            guard let index = newImages.firstIndex(where: { $0.id == id }) else { return nil }
            return IndexPath(item: index, section: 0)
        })
        if collectionView.selectionIndexPaths != desiredIndexPaths {
            collectionView.selectionIndexPaths = desiredIndexPaths
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
                        NSLog("[NovelAIViewer] サムネイル先読み生成に失敗: \(image.path): \(error)")
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
            parent.appModel.selectedImageIds = Set(ids)
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
                    NSLog("[NovelAIViewer] サムネイル生成に失敗（プレースホルダーのまま表示を継続）: \(path)")
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
