import SwiftUI
import NAICullerCore

/// 独立したヘルプウィンドウ（Helpメニュー／Cmd+?から開く）。ツールバーの「ショートカット」
/// ポップオーバーは作業中にサッと見る用の簡易版として残し、こちらは初見の人向けに
/// ワークフロー全体（使い方）まで含めた詳しい版として別立てにした（実際に使ってみての
/// フィードバックで追加：READMEは大半の人が読まないため、アプリ内で完結した説明が要る）。
struct HelpWindowView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("NAICullerの使い方").font(.title2.bold())
                    Text("NovelAIで生成したPNG画像を、タグ付け→絞り込み→選択→JSONエクスポートというワークフローで仕分けるためのビューワです。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("基本の流れ").font(.headline)
                    ForEach(Array(HelpContent.usageSteps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1).")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(step)
                                .font(.callout)
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("動作要件").font(.headline)
                    Text("プロンプトの読み取り・タグの書き込みに外部ツール「ExifTool」を使用します。未インストールの場合はスキャン・タグ付け機能が使えません。ターミナルで下記を実行してください。")
                        .font(.callout)
                    Text("brew install exiftool")
                        .font(.callout.monospaced())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("背景透過・シート分割（bg-splitterプラグイン）").font(.headline)
                    Text("自分専用の外部ツール「bg-splitter」（~/Dev/tools/bg-splitter）が入っている時だけ、右クリックメニューに「背景透過」「シート分割」が出るよ。設定画面の「背景透過・分割」タブでパス・デフォルトモデル・出力先を設定できる。")
                        .font(.callout)
                    Text("選べるモデル")
                        .font(.subheadline.bold())
                    ForEach(BgSplitterModel.all) { model in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.displayName).font(.callout.bold())
                            Text(model.usageHint)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("⚠️ 「この分割をやり直す」について")
                        .font(.subheadline.bold())
                        .padding(.top, 4)
                    Text("分割セルには「どの元シートから、どのモデル・余白設定で切り出したか」を記録したマニフェスト(_manifest.json)が付いている。分割した**後で元シートのファイル名を変更・移動すると、マニフェストが古いパスを指したままになり「この分割をやり直す」が失敗する**（分割セル自体は残るので実害はないが、やり直したい時は元シートから改めて「シート分割」し直してね）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("キーボードショートカット").font(.headline)
                    ShortcutsListContent()
                }
            }
            .padding(24)
        }
        .frame(minWidth: 420, idealWidth: 480, minHeight: 420, idealHeight: 560)
    }
}
