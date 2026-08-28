import Foundation

/// 「削除対象」タグ付き画像をバックアップフォルダへ移動する機能の、移動先ファイル名の決定ロジック。
///
/// `FileManager.moveItem`は移動先に同名ファイルが既にあると例外を投げるだけで上書きはしない
/// （安全な既定動作）が、そのまま使うと同名衝突のたびに移動全体が失敗扱いになってしまう。
/// Finderの「コピー - ファイル名 2.png」と同じ要領で、衝突時は末尾に連番を付けて回避する
/// （＝既存ファイルを上書きしない、というアプリ全体の破壊的操作を避ける方針を維持する）。
///
/// 実際の`FileManager`呼び出しはAppModel側で行う（テストしやすくするため、ここでは移動先フォルダの
/// 既存ファイル名の集合を`Set<String>`として受け取る純粋関数にしてある）。
public enum BackupMoveService {
    /// `folder`配下で`sourceURL`のファイル名と衝突しない移動先URLを返す。
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
