import AppKit
import SwiftUI
import NAICullerCore

/// ツールバーの「エクスポート」ボタンと、その項目選択ポップオーバー（詳細設計 4-3章：
/// 項目チェックボックス最低1つ必須、NSSavePanelで保存先選択）。
///
/// 元は`MainWindowView`のツールバー定義・ポップオーバー本体・保存処理が3箇所に分かれて
/// 置かれ、`exportFields` / `showExportPopover`の2つの`@State`だけが親に居座っていた。
/// この2つはエクスポート以外から一切参照されないので、ボタンごとここへ閉じ込める。
///
/// 「画像ファイルそのものをエクスポートしたい」というフィードバックで、JSON書き出しに加えて
/// 画像ファイル本体をフォルダへコピーするモードを追加した（実際に使ってみての想定用途：
/// サブディレクトリで絞り込み→削除対象タグ付け→削除対象を除外→残った画像をまるっと
/// 作業用ディレクトリへコピー）。保存先の種類が違う（JSON=単一ファイル／画像ファイル=フォルダ）
/// ため、1つのボタンで両方同時に実行するのではなく、モード切り替えにした。
struct ExportToolbarButton: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var showPopover = false
    @State private var fields: Set<ExportFieldKind> = Set(ExportFieldKind.allCases)

    private enum ExportMode: String, CaseIterable, Identifiable {
        case json = "JSON"
        case imageFiles = "画像ファイル"
        var id: String { rawValue }
    }
    @State private var mode: ExportMode = .json

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
            Picker("形式", selection: $mode) {
                ForEach(ExportMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if mode == .json {
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
            } else {
                Text("選択中の画像ファイル本体を、指定フォルダへコピーするよ。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("選択中の\(appModel.selectedImageIds.count)件が対象だよ")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(mode == .json ? "保存先を選んでエクスポート" : "コピー先フォルダを選んでエクスポート") {
                    performExport()
                }
                // JSON書き出しは最低1項目必須。0件時はエクスポートボタン無効化（詳細設計 2章）。
                // 画像ファイルモードには項目選択が無いので、対象が1件でもあれば常に有効。
                .disabled(mode == .json && fields.isEmpty)
            }
        }
        .padding()
        .frame(width: 280)
    }

    private func performExport() {
        let selectedImages = appModel.filteredImages.filter { appModel.selectedImageIds.contains($0.id) }
        guard !selectedImages.isEmpty else { return }

        switch mode {
        case .json:
            guard !fields.isEmpty else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = ExportService.defaultFileName()
            panel.allowedContentTypes = [.json]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let orderedFields = ExportFieldKind.allCases.filter { fields.contains($0) }
            appModel.exportImages(selectedImages, fields: orderedFields, to: url)
        case .imageFiles:
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "選択"
            panel.message = "コピー先のフォルダを選んでね"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            appModel.copyImagesToFolder(selectedImages, to: url)
        }
        showPopover = false
    }
}
