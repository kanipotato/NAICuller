import Foundation

/// タグ（`tags`テーブル1行に対応）。
///
/// お気に入り/削除対象のような固定タグ（`isSystem == true`）とユーザー定義タグの
/// 違いはこの構造体レベルでは持たず、`isSystem`フラグと`keyBinding`の有無だけで表現する。
/// F/G/1〜9キーの挙動はすべて「同じタグ機構への割当」として扱う（詳細設計 1章の通り）。
public struct Tag: Equatable, Identifiable, Sendable {
    public var id: Int64
    public var name: String
    public var isSystem: Bool
    /// "F" "G" "1"〜"9" のいずれか、または未割当ならnil。
    public var keyBinding: String?

    public init(id: Int64, name: String, isSystem: Bool, keyBinding: String?) {
        self.id = id
        self.name = name
        self.isSystem = isSystem
        self.keyBinding = keyBinding
    }

    /// サイドバーのタグ一覧で「用途:blog」のようなprefix付きタグを自動グルーピング表示するための
    /// カテゴリ名。`:`を含まないタグはnil（無カテゴリ扱い）。
    public var categoryPrefix: String? {
        guard let colonIndex = name.firstIndex(of: ":") else { return nil }
        let prefix = name[name.startIndex..<colonIndex]
        return prefix.isEmpty ? nil : String(prefix)
    }

    /// 固定タグ名（システムタグ）の定数。DatabaseServiceの初期マイグレーションで
    /// この名前・key_bindingで`tags`テーブルに投入する。
    public enum SystemTagName {
        public static let favorite = "お気に入り"
        public static let deletionMark = "削除対象"
    }
}
