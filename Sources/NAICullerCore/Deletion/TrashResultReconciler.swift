import Foundation

/// `NSWorkspace.recycle`のコールバックが返す「実際にゴミ箱へ移動できた元URL」と、
/// こちらが渡した対象レコードを突き合わせる。
///
/// 単純な`Set<URL>`の包含判定では駄目だという、実際に踏んだ落とし穴がある：
/// 渡した元URLと返ってくるキーは意味的に同じファイルでも、シンボリックリンクの解決や
/// 表記の正規化（`/private/var`と`/var`、末尾スラッシュ、`.`要素など）によって
/// URL/パス文字列がそのまま一致しないことがある。一致しないと「移動は成功したのに
/// 失敗と誤判定してDBレコードを消し忘れる」＝ゴミ箱の実体とDBがずれる事故になる。
///
/// `AppModel.performTrashDeletion`の中に埋まっていて単体で確かめられなかったため、
/// `standardizedFileURL`での正規化ごとここへ切り出した。
public enum TrashResultReconciler {
    /// 実際にゴミ箱へ移動できたレコードだけを、`targets`の並び順を保って返す。
    ///
    /// - Parameters:
    ///   - recycledOriginalURLs: `NSWorkspace.recycle`のコールバックで受け取る
    ///     `[元URL: 新URL]`辞書の**キー側**（＝移動に成功した元ファイルのURL）。
    public static func succeeded(
        targets: [ImageRecord],
        recycledOriginalURLs: some Sequence<URL>
    ) -> [ImageRecord] {
        let succeededPaths = Set(recycledOriginalURLs.map { $0.standardizedFileURL.path })
        return targets.filter { succeededPaths.contains($0.url.standardizedFileURL.path) }
    }

    /// 移動できなかった件数。
    public static func failureCount(
        targets: [ImageRecord],
        recycledOriginalURLs: some Sequence<URL>
    ) -> Int {
        targets.count - succeeded(targets: targets, recycledOriginalURLs: recycledOriginalURLs).count
    }
}
