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
