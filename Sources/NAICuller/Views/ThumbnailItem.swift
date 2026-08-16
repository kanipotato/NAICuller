import AppKit

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
