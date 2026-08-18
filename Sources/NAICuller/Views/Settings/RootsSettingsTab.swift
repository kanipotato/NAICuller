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
        // 追加直後の自動スキャンを含む一連の流れはAppModel側に集約してある
        // （設定画面だけスキャンが抜けていた過去の不具合の再発防止）。
        additionError = appModel.chooseAndAddRoot()
    }

}
