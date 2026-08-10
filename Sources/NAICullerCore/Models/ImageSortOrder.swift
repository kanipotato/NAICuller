import Foundation

/// グリッドの並び替え順（Finderの「名前」「サイズ」「作成日」に相当するものをNovelAI画像向けに用意）。
///
/// 「作成日」はDBに列を持たせず（詳細設計3章の通り、システム情報パネルでは都度FileManagerから
/// ライブ取得している）、ここでは代わりに`mtime`（差分スキャンで既にDBへ持っている値）を使う。
/// NovelAIが書き出した直後のファイルは作成日時と更新日時が実質一致するため、
/// 「新規追加したものを上に」という目的に対しては`mtime`で十分に代用できる。1万枚超を
/// 並び替えるたびにFileManagerへ都度アクセスするコストを避けられる利点もある。
public enum ImageSortOrder: String, CaseIterable, Identifiable, Hashable, Sendable {
    case dateNewest
    case dateOldest
    case nameAscending
    case nameDescending
    case sizeLargest
    case sizeSmallest

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .dateNewest: return "追加日時（新しい順）"
        case .dateOldest: return "追加日時（古い順）"
        case .nameAscending: return "ファイル名（A→Z）"
        case .nameDescending: return "ファイル名（Z→A）"
        case .sizeLargest: return "ファイルサイズ（大きい順）"
        case .sizeSmallest: return "ファイルサイズ（小さい順）"
        }
    }

    /// Finderの「名前」ソートと同じ挙動（"2"が"10"より前に来る等）にするため
    /// `localizedStandardCompare`を使う。
    public func sorted(_ images: [ImageRecord]) -> [ImageRecord] {
        switch self {
        case .dateNewest:
            return images.sorted { $0.mtime > $1.mtime }
        case .dateOldest:
            return images.sorted { $0.mtime < $1.mtime }
        case .nameAscending:
            return images.sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
        case .nameDescending:
            return images.sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedDescending }
        case .sizeLargest:
            return images.sorted { $0.fileSize > $1.fileSize }
        case .sizeSmallest:
            return images.sorted { $0.fileSize < $1.fileSize }
        }
    }
}
