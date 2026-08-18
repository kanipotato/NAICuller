import AppKit
import SwiftUI
import NAICullerCore

// MARK: - ExifToolタブ

struct ExifToolSettingsTab: View {
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
