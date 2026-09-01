import Foundation

/// あるフォルダへファイルを移動/コピーする際、移動先ファイル名の衝突を避けるロジック。
/// 「削除対象」タグ付き画像のバックアップフォルダへの移動と、選択画像本体のフォルダへの
/// コピー（画像エクスポート）の両方から共通で使う（元は`BackupMoveService`という名前で
/// 移動専用だったが、コピー機能の追加時に汎用化した）。
///
/// `FileManager.moveItem`/`copyItem`は移動・コピー先に同名ファイルが既にあると例外を投げるだけで
/// 上書きはしない（安全な既定動作）が、そのまま使うと同名衝突のたびに処理全体が失敗扱いになって
/// しまう。Finderの「コピー - ファイル名 2.png」と同じ要領で、衝突時は末尾に連番を付けて回避する
/// （＝既存ファイルを上書きしない、というアプリ全体の破壊的操作を避ける方針を維持する）。
///
/// 実際の`FileManager`呼び出しはAppModel側で行う（テストしやすくするため、ここでは移動/コピー先
/// フォルダの既存ファイル名の集合を`Set<String>`として受け取る純粋関数にしてある）。
public enum UniqueFileNaming {
    /// `folder`配下で`sourceURL`のファイル名と衝突しない移動/コピー先URLを返す。
    ///
    /// - Parameter existingNames: `folder`直下に既に存在するファイル名の集合（拡張子込み）。
    public static func uniqueDestinationURL(for sourceURL: URL, in folder: URL, existingNames: Set<String>) -> URL {
        let originalName = sourceURL.lastPathComponent
        guard existingNames.contains(originalName) else {
            return folder.appendingPathComponent(originalName)
        }
        let ext = sourceURL.pathExtension
        let stem = ext.isEmpty ? originalName : String(originalName.dropLast(ext.count + 1))
        var suffix = 2
        while true {
            let candidateName = ext.isEmpty ? "\(stem) \(suffix)" : "\(stem) \(suffix).\(ext)"
            if !existingNames.contains(candidateName) {
                return folder.appendingPathComponent(candidateName)
            }
            suffix += 1
        }
    }
}
