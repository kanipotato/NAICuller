import Foundation

/// 「削除対象」タグが付いた画像だけを抜き出す。
///
/// 元は`AppModel`の`selectedMarkedImages()` / `allMarkedImages()`として、
/// リポジトリ問い合わせと一緒に書かれていた（`@MainActor` + DB依存でテスト不能）。
/// 「どの画像を対象にするか」の判定はタグID集合と選択集合があれば決まるので、
/// 問い合わせ結果を受け取る純粋関数としてここへ切り出す。
///
/// この判定を間違えると、タグの付いていない画像をゴミ箱やバックアップフォルダへ
/// 移動してしまう（＝ユーザーのファイルを意図せず動かす）ため、テストで固定する。
public enum MarkedImageSelector {
    /// 選択中かつ「削除対象」タグが付いている画像だけを、`images`の並び順を保って返す。
    ///
    /// - Parameters:
    ///   - markedIds: 「削除対象」タグが付いている画像IDの集合。
    ///   - selectedIds: グリッドで選択中の画像IDの集合。
    public static func selected(
        from images: [ImageRecord],
        markedIds: Set<Int64>,
        selectedIds: Set<Int64>
    ) -> [ImageRecord] {
        images.filter { selectedIds.contains($0.id) && markedIds.contains($0.id) }
    }

    /// 選択状態やフィルタとは無関係に、「削除対象」タグが付いている画像すべてを返す。
    public static func all(from images: [ImageRecord], markedIds: Set<Int64>) -> [ImageRecord] {
        images.filter { markedIds.contains($0.id) }
    }
}
