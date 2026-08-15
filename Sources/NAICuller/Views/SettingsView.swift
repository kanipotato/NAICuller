import SwiftUI
import AppKit
import NAICullerCore

/// 設定ウィンドウ：監視ルートディレクトリの追加/削除、カスタムタグのキー割当（1〜9）（詳細設計 1章）。
struct SettingsView: View {
    var body: some View {
        TabView {
            RootsSettingsTab()
                .tabItem { Label("ルート", systemImage: "folder") }
            KeyBindingsSettingsTab()
                .tabItem { Label("キー割当", systemImage: "keyboard") }
            ExifToolSettingsTab()
                .tabItem { Label("ExifTool", systemImage: "wrench.and.screwdriver") }
            BgSplitterSettingsTab()
                .tabItem { Label("背景透過・分割", systemImage: "puzzlepiece.extension") }
        }
        .padding()
    }
}

// MARK: - ルート管理タブ

private struct RootsSettingsTab: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var additionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            List {
                ForEach(appModel.roots) { root in
                    HStack {
                        Text(root.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            appModel.removeRoot(id: root.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if let additionError {
                Text(additionError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Button("ルートを追加...") { chooseRoot() }
                Spacer()
                Button {
                    appModel.rescan()
                } label: {
                    if appModel.isScanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("再スキャン", systemImage: "arrow.clockwise")
                    }
                }
                // メインウィンドウのツールバーと同じ無効化条件（詳細設計 2章）。
                .disabled(!appModel.exifToolAvailable || appModel.isScanning || appModel.roots.isEmpty)
            }
        }
    }

    private func chooseRoot() {
        additionError = nil
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "追加"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let failure = appModel.addRoot(path: url.path) {
            additionError = describe(failure)
        } else {
            // メインウィンドウの「ルート追加」と同じく、追加直後に自動でスキャンする
            // （設定画面だけこれが抜けており、ルートを追加/再追加しても画像が0件のまま
            // 何も起きたように見えないバグがあった。ユーザーが手動で「削除→再追加」を
            // 試したときに気づいた）。
            appModel.rescan()
        }
    }

    private func describe(_ failure: RootPathValidator.Failure) -> String {
        switch failure {
        case .notExisting: return "指定したパスが存在しません。"
        case .notDirectory: return "指定したパスはディレクトリではありません。"
        case .duplicateOrContained(let existingPath): return "既存のルート「\(existingPath)」と重複しているか、包含関係にあります。"
        }
    }
}

// MARK: - キー割当タブ

private struct KeyBindingsSettingsTab: View {
    private static let keys = (1...9).map(String.init)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("1〜9キーに割り当てるカスタムタグ名を設定できるよ。空欄で保存すると割当を解除するよ。")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(Self.keys, id: \.self) { key in
                        CustomTagKeyRow(key: key)
                    }
                }
            }
        }
    }
}

private struct CustomTagKeyRow: View {
    @EnvironmentObject private var appModel: AppModel
    let key: String

    @State private var text: String = ""
    @State private var isEditing = false
    @State private var showOverwriteConfirm = false
    @State private var pendingWarningMessage = ""

    private var boundTag: Tag? {
        appModel.tags.first(where: { $0.keyBinding == key })
    }

    private var normalizedInput: String? {
        TagNameValidator.normalize(text)
    }

    private var validationFailure: TagNameValidator.Failure? {
        text.isEmpty ? nil : TagNameValidator.validate(text)
    }

    /// 空なら保存ボタン無効化（詳細設計 2章）。既存の割当と同じ内容のときも保存不要。
    private var isSaveEnabled: Bool {
        guard let normalizedInput else { return false }
        return normalizedInput != boundTag?.name
    }

    var body: some View {
        HStack {
            Text(key)
                .font(.system(.body, design: .monospaced))
                .frame(width: 20)
            TextField("タグ名（未割当なら空欄）", text: $text, onEditingChanged: { editing in
                isEditing = editing
            })
            .textFieldStyle(.roundedBorder)
            // 制御文字や空白のみは赤枠で示す（詳細設計 2章）。
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(validationFailure != nil ? Color.red : Color.clear, lineWidth: 1.5)
            )
            Button("保存") { attemptSave() }
                .disabled(!isSaveEnabled)
            Button("解除") {
                appModel.clearCustomTag(key: key)
                text = ""
            }
            .disabled(boundTag == nil)
        }
        .onAppear { text = boundTag?.name ?? "" }
        .onChange(of: appModel.tags) { _ in
            if !isEditing { text = boundTag?.name ?? "" }
        }
        .alert("上書き確認", isPresented: $showOverwriteConfirm) {
            Button("上書き", role: .destructive) { performSave() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text(pendingWarningMessage)
        }
    }

    private func attemptSave() {
        guard normalizedInput != nil else { return }
        if let warning = appModel.conflictWarning(forKey: key, name: text) {
            pendingWarningMessage = warning
            showOverwriteConfirm = true
        } else {
            performSave()
        }
    }

    private func performSave() {
        _ = appModel.assignCustomTag(key: key, name: text)
    }
}

// MARK: - ExifToolタブ

private struct ExifToolSettingsTab: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        VStack(spacing: 12) {
            // 初見だと「なぜ画像ビューワなのに外部ツールが要るのか」が分かりにくいとの
            // フィードバックを受けて追加した一言説明（実際に使ってみてのフィードバックで追加）。
            Text("プロンプトの読み取り・タグの書き込みに使う外部ツールだよ。無いとスキャン・タグ付けが動かないので必須。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if appModel.exifToolAvailable {
                Label("ExifToolを検出済み", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("ExifToolが見つからないよ", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("ターミナルで `brew install exiftool` を実行してからもう一度チェックしてね。")
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
            Button("再チェック") { appModel.recheckExifTool() }
        }
        .padding()
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 背景透過・シート分割タブ（bg-splitterプラグイン）

/// bg-splitterは自分専用の未公開Pythonツールなので「プラグイン」扱い。見つからなくても
/// アプリ本体（スキャン・タグ付け等）には一切影響しない。他のNAICullerユーザーには
/// 「そもそも無い機能」として振る舞う（ExifToolのような必須ツールとは重みが違う）。
private struct BgSplitterSettingsTab: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var pathText: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("背景透過・シート分割は「bg-splitter」というプラグイン経由の機能だよ。自分専用のPythonツールで、無くても他の機能には影響しないよ。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                statusSection

                HStack {
                    TextField("bg-splitterのフォルダ（空欄で ~/Dev/tools/bg-splitter）", text: $pathText)
                        .textFieldStyle(.roundedBorder)
                    Button("選択...") { choosePath() }
                    Button("再チェック") { applyPathAndRecheck() }
                }

                if appModel.bgSplitterAvailable {
                    Divider()
                    modelSection
                    Divider()
                    OutputPathRow(title: "背景透過の出力先", path: $appModel.bgSplitterRemoveOutputPath)
                    OutputPathRow(title: "シート分割の出力先", path: $appModel.bgSplitterSplitOutputPath)
                    Divider()
                    OutputPathRow(title: "分割履歴(マニフェスト)の保存先", path: $appModel.bgSplitterManifestPath)
                    Text("空欄だとシート分割の出力先ごとに小さいJSONファイル(<元名>_manifest.json)が溜まっていくよ。「この分割をやり直す」機能が使う元シートの記録なので、たくさん処理してファイルが増えてきたら、ここで専用フォルダにまとめて後で確認・削除しやすくできるよ。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .onAppear { pathText = appModel.bgSplitterCustomPath }
    }

    @ViewBuilder
    private var statusSection: some View {
        if appModel.bgSplitterAvailable {
            Label("bg-splitterを検出済み", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Label("bg-splitterが見つからないよ", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("下のパスに無いか確認してね。まだセットアップしていない場合はターミナルで:")
                .font(.caption)
            Text("cd ~/Dev/tools/bg-splitter\npython3 -m venv venv\n./venv/bin/pip install Pillow numpy onnxruntime \"rembg[cpu]\"")
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
        Picker("デフォルトモデル", selection: $appModel.bgSplitterDefaultModel) {
            ForEach(BgSplitterModel.all) { model in
                Text(model.displayName).tag(model.id)
            }
        }
        if let hint = BgSplitterModel.all.first(where: { $0.id == appModel.bgSplitterDefaultModel })?.usageHint {
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
        appModel.bgSplitterCustomPath = pathText
        appModel.recheckBgSplitter()
    }
}

private struct OutputPathRow: View {
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
