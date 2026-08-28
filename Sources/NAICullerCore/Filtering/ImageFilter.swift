import Foundation

/// グリッドに出す画像を絞り込む条件一式。
///
/// 元は`AppModel.refreshFilteredImages()`の中に直接書かれていたが、
/// 条件が5系統（ルート/タグ/削除対象/プロンプト検索/プロンプト候補）まで増えて
/// 分岐の組み合わせが単体で確かめられなくなっていたため、`AppModel`（SwiftUI/AppKit依存・
/// テスト不能）から切り離してCore層の純粋なデータとして持つ。
public struct ImageFilterCriteria: Equatable, Sendable {
    /// rootId→ルート絶対パス。ここに無いrootIdの画像は常に除外する（ルートが削除された場合など）。
    /// フォルダツリー絞り込み機能の導入で`enabledRootIds`を廃止し、これと`folderVisibilityOverrides`に
    /// 置き換えた（ツリーのルート直下ノードが旧`enabledRootIds`と同じ役割を果たすため）。
    public var rootPaths: [Int64: String]
    /// サイドバーのフォルダツリーで明示的に設定されたON/OFF。`FolderVisibilityResolver`が
    /// 「最も近い祖先の設定が勝つ」方式で実効の表示/非表示を解決する。
    public var folderVisibilityOverrides: [FolderVisibilityKey: Bool]
    /// タグ絞り込み（AND条件：選択した全タグを持つ画像のみ残す）。空なら絞り込まない。
    public var selectedTagIds: Set<Int64>
    /// 「未タグのみ表示」。trueのときは`selectedTagIds`より優先され、タグを1つも持たない画像だけ残す
    /// （UI上も排他になっている）。
    public var showUntaggedOnly: Bool
    /// 「削除対象」タグのID。nil以外なら、そのタグが付いた画像を除外する
    /// （「削除対象を隠す」がOFF、またはタグ自体が未作成のときはnil）。
    public var hiddenDeletionMarkTagId: Int64?
    /// プロンプト本文へのインクリメンタル検索語（大文字小文字を無視した部分一致）。空なら絞り込まない。
    public var promptSearchText: String
    /// プロンプト候補絞り込みで選ばれた語句（AND条件：全部含む画像のみ残す）。空なら絞り込まない。
    public var selectedPromptTerms: Set<String>
    /// サイドバーでチェックが入っている生成元プラットフォーム。ここに無いプラットフォームの
    /// 画像は除外する（Stable Diffusion/ComfyUI対応で追加。他条件と同じくAND結合の一部）。
    public var enabledSourcePlatforms: Set<ImageSourcePlatform>

    public init(
        rootPaths: [Int64: String] = [:],
        folderVisibilityOverrides: [FolderVisibilityKey: Bool] = [:],
        selectedTagIds: Set<Int64> = [],
        showUntaggedOnly: Bool = false,
        hiddenDeletionMarkTagId: Int64? = nil,
        promptSearchText: String = "",
        selectedPromptTerms: Set<String> = [],
        enabledSourcePlatforms: Set<ImageSourcePlatform> = Set(ImageSourcePlatform.allCases)
    ) {
        self.rootPaths = rootPaths
        self.folderVisibilityOverrides = folderVisibilityOverrides
        self.selectedTagIds = selectedTagIds
        self.showUntaggedOnly = showUntaggedOnly
        self.hiddenDeletionMarkTagId = hiddenDeletionMarkTagId
        self.promptSearchText = promptSearchText
        self.selectedPromptTerms = selectedPromptTerms
        self.enabledSourcePlatforms = enabledSourcePlatforms
    }
}

public enum ImageFilter {
    /// `criteria`の全条件をAND結合して適用する（並び替えは呼び出し側の`ImageSortOrder.sorted`が担当）。
    ///
    /// - Parameters:
    ///   - imageTagIds: 画像ID→タグIDの対応表。`AppModel`がグリッド用に持っているキャッシュをそのまま渡す。
    ///   - promptTerms: 画像1件分のプロンプト語句集合を返すクロージャ。
    ///     呼び出し側（`AppModel`）が画像IDをキーにキャッシュしているため、ここでは分割処理を持たず注入で受ける
    ///     （2万枚規模では打鍵のたびに全画像のプロンプトを再分割すると体感できる停止になる、という経緯がある）。
    ///     `selectedPromptTerms`が空のときは一度も呼ばれない。
    public static func apply(
        to images: [ImageRecord],
        imageTagIds: [Int64: Set<Int64>],
        criteria: ImageFilterCriteria,
        promptTerms: (ImageRecord) -> Set<String>
    ) -> [ImageRecord] {
        images.filter { image in
            // 生成元プラットフォームの絞り込み（O(1)）を先に見てから、パス解析を伴うフォルダ判定に進む
            // （レビュー指摘：安いガードを先に置くことでフォルダ判定の文字列処理を無駄に走らせない）。
            guard criteria.enabledSourcePlatforms.contains(image.sourcePlatform) else { return false }
            guard FolderVisibilityResolver.isImageVisible(
                image,
                rootPaths: criteria.rootPaths,
                overrides: criteria.folderVisibilityOverrides
            ) else { return false }

            if criteria.showUntaggedOnly {
                guard (imageTagIds[image.id] ?? []).isEmpty else { return false }
            } else if !criteria.selectedTagIds.isEmpty {
                guard let tagIds = imageTagIds[image.id],
                      criteria.selectedTagIds.isSubset(of: tagIds) else { return false }
            }

            if let deletionMarkId = criteria.hiddenDeletionMarkTagId,
               imageTagIds[image.id]?.contains(deletionMarkId) == true {
                return false
            }

            if !criteria.promptSearchText.isEmpty {
                guard let prompt = image.promptCache,
                      prompt.range(of: criteria.promptSearchText, options: [.caseInsensitive]) != nil else { return false }
            }

            if !criteria.selectedPromptTerms.isEmpty {
                guard image.promptCache != nil else { return false }
                guard criteria.selectedPromptTerms.isSubset(of: promptTerms(image)) else { return false }
            }

            return true
        }
    }
}
