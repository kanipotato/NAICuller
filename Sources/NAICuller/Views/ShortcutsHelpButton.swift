import SwiftUI

/// ツールバーの「ショートカット」ボタンと、使い方＋キーボードショートカットのポップオーバー
/// （画面のどこにも表示が無いとの指摘に対応して追加したもの）。
///
/// 内容は作業中にサッと見る用の凝縮版で、初見でじっくり読む用のフル説明は
/// 独立ヘルプウィンドウ（Helpメニュー / このポップオーバー内のリンク）側にある。
struct ShortcutsHelpButton: View {
    @Environment(\.openWindow) private var openWindow
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover = true
        } label: {
            Label("ショートカット", systemImage: "keyboard")
        }
        .help("キーボードショートカット一覧")
        .popover(isPresented: $showPopover) {
            popoverContent
        }
    }

    private var popoverContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("使い方").font(.headline)
                ForEach(Array(HelpContent.usageSteps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(index + 1).")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(step)
                            .font(.caption)
                    }
                }
                Button {
                    showPopover = false
                    openWindow(id: "help")
                } label: {
                    Label("もっと詳しく（ヘルプウィンドウ）", systemImage: "questionmark.circle")
                        .font(.caption)
                }
                .buttonStyle(.link)

                Divider()

                Text("キーボードショートカット").font(.headline)
                ShortcutsListContent()
            }
            .padding()
            .frame(width: 280)
        }
        .frame(maxHeight: 420)
    }
}
