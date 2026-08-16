import AppKit
import SwiftUI
import NAICullerCore

// MARK: - ルート管理タブ

struct RootsSettingsTab: View {
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
            additionError = failure.message
        } else {
            // メインウィンドウの「ルート追加」と同じく、追加直後に自動でスキャンする
            // （設定画面だけこれが抜けており、ルートを追加/再追加しても画像が0件のまま
            // 何も起きたように見えないバグがあった。ユーザーが手動で「削除→再追加」を
            // 試したときに気づいた）。
            appModel.rescan()
        }
    }

}
