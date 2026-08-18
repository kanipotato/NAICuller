import Foundation

/// 失敗したファイル名の一覧を、ダイアログに載せられる長さへ丸めて1行にする。
///
/// 一括タグ付けで数十件まとめて失敗しうるため、全部並べるとアラートが画面外まで
/// 伸びてしまう。先頭N件だけ出して残りは件数で示す。
///
/// 元は`AppModel`の一括タグ付けの中に`prefix(5)`と三項演算子で直書きされていた。
/// 「ちょうどN件のときに"他0件"と出さない」「1件も無ければ空文字」といった境界が
/// 目で追いにくいため、単体で固定できるようここへ出した。
public enum FailureSummary {
    /// - Parameters:
    ///   - maxShown: 名前をそのまま並べる最大件数。これを超えた分は「他N件」に畳む。
    /// - Returns: 例）`"a.png、b.png、他3件"`。`names`が空なら空文字列。
    public static func text(names: [String], maxShown: Int = 5) -> String {
        guard !names.isEmpty else { return "" }
        guard maxShown > 0 else { return "他\(names.count)件" }
        let shown = names.prefix(maxShown).joined(separator: "、")
        let remaining = names.count - min(maxShown, names.count)
        return remaining > 0 ? "\(shown)、他\(remaining)件" : shown
    }
}
