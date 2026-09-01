import AppKit
import SwiftUI
import NAICullerCore

// MARK: - ルート管理タブ

struct RootsSettingsTab: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var additionError: String?
    @State private var showForceRescanConfirmation = false

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

            Divider()

            // 強制再スキャン（実際に使ってみてのフィードバックで追加）：アプリの機能追加で
            // メタデータの読み取り項目が増えても、差分スキャンの仕組み上mtime/file_size一致
            // ファイルはExifTool再読み込み自体をスキップするため、通常の「再スキャン」では
            // v1時代からの既存画像に反映されない不具合を実機で2回踏んだ（source_platform・
            // 生成パラメータ対応）。普段使いのボタンではなく「リセット用」という位置づけが
            // 伝わるよう、赤色・注意書き付きで明確に分けて置く。
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    showForceRescanConfirmation = true
                } label: {
                    if appModel.isScanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("強制再スキャン")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!appModel.exifToolAvailable || appModel.isScanning || appModel.roots.isEmpty)

                Text("アプリのアップデートや、画像が読み込めなくなった時などリセットしたい場合にのみ押してください（※画像量が多いほど時間がかかります）")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .alert("強制再スキャンしますか？", isPresented: $showForceRescanConfirmation) {
            Button("強制再スキャン", role: .destructive) {
                appModel.rescan(forceFullRescan: true)
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("変更の無いファイルも含めて、登録済みの全画像をExifToolで再読み込みします。画像量が多いほど時間がかかります。")
        }
    }

    private func chooseRoot() {
        // 追加直後の自動スキャンを含む一連の流れはAppModel側に集約してある
        // （設定画面だけスキャンが抜けていた過去の不具合の再発防止）。
        additionError = appModel.chooseAndAddRoot()
    }

}
