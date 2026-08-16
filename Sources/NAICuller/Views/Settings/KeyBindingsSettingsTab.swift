import AppKit
import SwiftUI
import NAICullerCore

// MARK: - キー割当タブ

struct KeyBindingsSettingsTab: View {
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

struct CustomTagKeyRow: View {
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
