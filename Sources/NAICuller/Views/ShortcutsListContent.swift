import SwiftUI
import NAICullerCore

/// ショートカット一覧の中身。ツールバーの簡易ポップオーバーと独立したヘルプウィンドウ
/// （`HelpWindowView`）の両方から使う共通部品（実際に使ってみてのフィードバックで、
/// 「作業中にサッと見たい」ポップオーバーと「初見でじっくり読みたい」ヘルプウィンドウの
/// 両方を用意することにしたため、内容がズレないよう1箇所にまとめた）。
struct ShortcutsListContent: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("← → / ↑ ↓", "前後の画像へ移動（プレビュー維持）")
            row("Space", "フォーカス中の画像をQuick Lookで大きく表示")
            Divider()
            row("F", "お気に入り（トグル）")
            row("G", "削除対象としてマーク（トグル）")
            Divider()
            Text("カスタムタグ（設定 > キー割当で変更）")
                .font(.caption)
                .foregroundStyle(.secondary)
            let customTagRows = appModel.tags
                .filter { $0.keyBinding.flatMap(Int.init) != nil }
                .sorted { ($0.keyBinding ?? "") < ($1.keyBinding ?? "") }
            if customTagRows.isEmpty {
                Text("未設定だよ")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(customTagRows) { tag in
                    row(tag.keyBinding ?? "", tag.name)
                }
            }
        }
    }

    private func row(_ key: String, _ description: String) -> some View {
        HStack(alignment: .top) {
            Text(key)
                .font(.caption.monospaced())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            Text(description)
                .font(.caption)
            Spacer()
        }
    }
}
