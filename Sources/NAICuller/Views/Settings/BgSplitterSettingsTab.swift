import AppKit
import SwiftUI
import NAICullerCore

// MARK: - 背景透過・シート分割タブ（bg-splitterプラグイン）

/// bg-splitterは自分専用の未公開Pythonツールなので「プラグイン」扱い。見つからなくても
/// アプリ本体（スキャン・タグ付け等）には一切影響しない。他のNAICullerユーザーには
/// 「そもそも無い機能」として振る舞う（ExifToolのような必須ツールとは重みが違う）。
struct BgSplitterSettingsTab: View {
    // AppModelではなくBgSplitterControllerを直接観測する。ネストしたObservableObjectの
    // @Published変更は親のobjectWillChangeを発火しないため、AppModel経由で参照すると
    // 検出状態やモデル選択の変化が画面に反映されない。
    @EnvironmentObject private var bgSplitter: BgSplitterController
    @State private var pathText: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("背景透過・シート分割は「bg-splitter」というプラグイン経由の機能だよ。自分専用のPythonツールで、無くても他の機能には影響しないよ。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                statusSection

                HStack {
                    TextField("bg-splitterのフォルダ（空欄で既定パスを使用）", text: $pathText)
                        .textFieldStyle(.roundedBorder)
                    Button("選択...") { choosePath() }
                    Button("再チェック") { applyPathAndRecheck() }
                }

                if bgSplitter.isAvailable {
                    Divider()
                    modelSection
                    Divider()
                    OutputPathRow(title: "背景透過の出力先", path: $bgSplitter.removeOutputPath)
                    OutputPathRow(title: "シート分割の出力先", path: $bgSplitter.splitOutputPath)
                    Divider()
                    OutputPathRow(title: "分割履歴(マニフェスト)の保存先", path: $bgSplitter.manifestPath)
                    Text("空欄だとシート分割の出力先ごとに小さいJSONファイル(<元名>_manifest.json)が溜まっていくよ。「この分割をやり直す」機能が使う元シートの記録なので、たくさん処理してファイルが増えてきたら、ここで専用フォルダにまとめて後で確認・削除しやすくできるよ。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .onAppear { pathText = bgSplitter.customPath }
        // コードレビュー指摘の修正：以前は「選択...」か「再チェック」を押した時だけ
        // appModelへ反映していたため、手入力しただけで設定画面を閉じると入力が
        // 跡形もなく消えていた（他の出力先欄はappModelへ直接バインドしていて即時保存
        // されるのに、ここだけ挙動が違っていた）。入力のたびに永続化だけは行い、
        // 実際のパス再検出（ディスクアクセス）は「再チェック」ボタンでのみ行う。
        .onChange(of: pathText) { newValue in
            bgSplitter.customPath = newValue
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if bgSplitter.isAvailable {
            Label("bg-splitterを検出済み", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Label("bg-splitterが見つからないよ", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("下のパスに無いか確認してね。まだセットアップしていない場合はbg-splitterのフォルダで:")
                .font(.caption)
            Text("python3 -m venv venv\n./venv/bin/pip install Pillow numpy onnxruntime \"rembg[cpu]\"")
                .font(.caption.monospaced())
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            Text("別の場所に置いている場合は下の欄でパスを指定してね。")
                .font(.caption)
        }
    }

    @ViewBuilder
    private var modelSection: some View {
        Picker("デフォルトモデル", selection: $bgSplitter.defaultModel) {
            ForEach(BgSplitterModel.all) { model in
                Text(model.displayName).tag(model.id)
            }
        }
        if let hint = BgSplitterModel.all.first(where: { $0.id == bgSplitter.defaultModel })?.usageHint {
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Text("右クリックメニューの「背景透過」「シート分割」はこのモデルで実行されるよ。別モデルを使いたい時だけ「モデルを指定」サブメニューから選んでね。")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "選択"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pathText = url.path
        applyPathAndRecheck()
    }

    private func applyPathAndRecheck() {
        bgSplitter.customPath = pathText
        bgSplitter.recheck()
    }
}

struct OutputPathRow: View {
    let title: String
    @Binding var path: String

    var body: some View {
        HStack {
            Text(title)
            TextField("空欄で元画像と同じ場所", text: $path)
                .textFieldStyle(.roundedBorder)
            Button("選択...") { choose() }
            if !path.isEmpty {
                Button("既定に戻す") { path = "" }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "選択"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        path = url.path
    }
}
