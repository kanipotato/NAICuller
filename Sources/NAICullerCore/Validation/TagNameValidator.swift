import Foundation

/// タグ名（自由入力タグ／カスタムタグ名1〜9共通）のバリデーション。
///
/// UI依存を持たない純粋関数として切り出し、DatabaseService/UI両方から
/// 同じルールを参照できるようにする（詳細設計 2章）。
public enum TagNameValidator {
    /// 文字数上限（仮置き）。
    public static let maxLength = 64

    public enum Failure: Equatable, Sendable {
        /// トリム後に空文字（空白のみを含む）。
        case empty
        /// 改行・タブ等の制御文字を含む。
        case containsControlCharacters
        /// 文字数上限（64文字）を超えている。
        case tooLong
    }

    /// 検証のみ行い、正規化はしない版。UI側で「赤枠にするかどうか」の判定に使う。
    public static func validate(_ rawName: String) -> Failure? {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .empty
        }
        if trimmed.count > maxLength {
            return .tooLong
        }
        // 改行・タブ等の制御文字（Unicode General Category Cc/Cf相当）が含まれていないか。
        // trimming後の文字列に対して判定する（先頭末尾の空白はトリムで除去済みのため、
        // ここで引っかかるのは文字列の途中に制御文字が挟まっているケース）。
        if trimmed.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            return .containsControlCharacters
        }
        return nil
    }

    /// 検証してOKなら正規化済み（トリム済み）の文字列を返す。NGならnil。
    public static func normalize(_ rawName: String) -> String? {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validate(rawName) == nil else { return nil }
        return trimmed
    }

    /// 既存タグとの同一判定（大文字小文字を区別しない）。
    /// 自由入力タグは「同名タグは既存タグに紐付け、新規作成しない」というルールのため使用する。
    public static func isSameName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: .caseInsensitive) == .orderedSame
    }
}
