import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// サムネイルサイズの5段階（詳細設計 1章：ツールバーのサムネサイズスライダー用）。
public enum ThumbnailSize: Int, CaseIterable, Sendable, Comparable {
    case extraSmall = 0
    case small
    case medium
    case large
    case extraLarge

    /// `kCGImageSourceThumbnailMaxPixelSize`に渡す一辺の最大ピクセル数。
    public var maxPixelSize: CGFloat {
        switch self {
        case .extraSmall: return 80
        case .small: return 120
        case .medium: return 180
        case .large: return 240
        case .extraLarge: return 320
        }
    }

    public static func < (lhs: ThumbnailSize, rhs: ThumbnailSize) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// サムネイルのディスクキャッシュ生成・管理。
///
/// `~/Library/Caches/<bundle-id>/thumbnails/<images.id>.jpg`にJPEG（品質0.7、仮置き）で保存する
/// （詳細設計 0章）。`CGImageSourceCreateThumbnailAtIndex`でフルデコードせず縮小デコードするため、
/// 1万枚規模でもメモリ・CPUへの負荷を抑えられる。表示直前の遅延生成・先読みはUI層
/// （ThumbnailGridView）がバックグラウンドキューからこのサービスを呼ぶことで実現する。
///
/// AppKit（NSImage）には依存させず、CoreGraphics/ImageIOのみを使う。GUIなしでswift testが
/// 走るCoreターゲットの方針（既存アプリ群のAudioSwitcherCore等と同じ流儀）に合わせるため。
/// 保持する状態（キャッシュディレクトリのURL・FileManager）はinit後不変で、ファイルI/O自体は
/// スレッドセーフなため、バックグラウンドキューからの呼び出しを前提に`Sendable`を明示する
/// （設計上も「表示直前の遅延生成・先読みをバックグラウンドキューで行う」ため必須）。
public final class ThumbnailService: @unchecked Sendable {
    public struct ThumbnailError: Error, CustomStringConvertible, Sendable {
        public let message: String
        public var description: String { message }
    }

    public let cacheDirectory: URL
    private let fileManager: FileManager

    public init(bundleIdentifier: String, fileManager: FileManager = .default) {
        let cachesRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        self.cacheDirectory = cachesRoot
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("thumbnails", isDirectory: true)
        self.fileManager = fileManager
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    /// テスト等でキャッシュディレクトリを直接指定したい場合用。
    public init(cacheDirectory: URL, fileManager: FileManager = .default) {
        self.cacheDirectory = cacheDirectory
        self.fileManager = fileManager
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    public func cacheFileURL(imageId: Int64) -> URL {
        cacheDirectory.appendingPathComponent("\(imageId).jpg")
    }

    public func hasCachedData(imageId: Int64) -> Bool {
        fileManager.fileExists(atPath: cacheFileURL(imageId: imageId).path)
    }

    /// キャッシュ済みJPEGデータ。無ければnil（呼び出し側で`generate`を呼ぶ）。
    public func cachedData(imageId: Int64) -> Data? {
        fileManager.contents(atPath: cacheFileURL(imageId: imageId).path)
    }

    /// mtimeが変わった／ファイルが更新された画像のキャッシュを破棄する。
    /// ScanServiceの`changedImageIds`に対して呼ぶ想定（詳細設計 0章：「mtimeが変わったら
    /// キャッシュ削除して再生成」）。
    public func invalidate(imageId: Int64) {
        try? fileManager.removeItem(at: cacheFileURL(imageId: imageId))
    }

    /// フルデコードせず縮小デコードでサムネイルを生成し、ディスクキャッシュに書き込んで返す。
    /// 失敗時（壊れたPNG等）はThumbnailErrorを投げる。呼び出し側はプレースホルダー画像を表示し、
    /// ログに記録した上でスキャン自体は継続すること（詳細設計 5章）。
    @discardableResult
    public func generate(imageId: Int64, sourcePath: String, size: ThumbnailSize) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: sourcePath) as CFURL, nil) else {
            throw ThumbnailError(message: "画像を開けなかった: \(sourcePath)")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: size.maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ThumbnailError(message: "縮小デコードに失敗した（壊れたPNGの可能性）: \(sourcePath)")
        }

        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ThumbnailError(message: "JPEGエンコーダの作成に失敗した")
        }
        let destinationProperties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.7]
        CGImageDestinationAddImage(destination, thumbnail, destinationProperties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ThumbnailError(message: "JPEGエンコードに失敗した: \(sourcePath)")
        }

        let jpegData = mutableData as Data
        try jpegData.write(to: cacheFileURL(imageId: imageId), options: .atomic)
        return jpegData
    }
}
