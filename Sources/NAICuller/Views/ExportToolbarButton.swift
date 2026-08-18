import AppKit
import SwiftUI
import NAICullerCore

/// ツールバーの「エクスポート」ボタンと、その項目選択ポップオーバー（詳細設計 4-3章：
/// 項目チェックボックス最低1つ必須、NSSavePanelで保存先選択）。
///
/// 元は`MainWindowView`のツールバー定義・ポップオーバー本体・保存処理が3箇所に分かれて
/// 置かれ、`exportFields` / `showExportPopover`の2つの`@State`だけが親に居座っていた。
/// この2つはエクスポート以外から一切参照されないので、ボタンごとここへ閉じ込める。
struct ExportToolbarButton: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var showPopover = false
    @State private var fields: Set<ExportFieldKind> = Set(ExportFieldKind.allCases)

    var body: some View {
        Button {
            showPopover = true
        } label: {
            Label("エクスポート", systemImage: "square.and.arrow.up")
        }
        .disabled(appModel.selectedImageIds.isEmpty)
        .popover(isPresented: $showPopover) {
            popoverContent
        }
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("エクスポート項目").font(.headline)
            ForEach(ExportFieldKind.allCases) { field in
                Toggle(isOn: Binding(
                    get: { fields.contains(field) },
                    set: { isOn in
                        if isOn { fields.insert(field) } else { fields.remove(field) }
                    }
                )) {
                    Text(field.displayName)
                }
            }
            Text("選択中の\(appModel.selectedImageIds.count)件を書き出すよ")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("保存先を選んでエクスポート") { performExport() }
                    // 最低1項目必須。0件時はエクスポートボタン無効化（詳細設計 2章）。
                    .disabled(fields.isEmpty)
            }
        }
        .padding()
        .frame(width: 260)
    }

    private func performExport() {
        let selectedImages = appModel.filteredImages.filter { appModel.selectedImageIds.contains($0.id) }
        guard !selectedImages.isEmpty, !fields.isEmpty else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = ExportService.defaultFileName()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let orderedFields = ExportFieldKind.allCases.filter { fields.contains($0) }
        appModel.exportImages(selectedImages, fields: orderedFields, to: url)
        showPopover = false
    }
}
