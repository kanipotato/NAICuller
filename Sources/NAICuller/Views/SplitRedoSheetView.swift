import SwiftUI
import NAICullerCore

/// 「シート分割をやり直す」確認シート。マニフェストの`overflow`（前回使った値）を
/// スライダーの初期値にし、結果を見てから微調整して再実行する運用を想定している。
struct SplitRedoSheetView: View {
    @EnvironmentObject private var bgSplitter: BgSplitterController
    @Environment(\.dismiss) private var dismiss
    let request: BgSplitterController.SplitRedoRequest

    @State private var overflow: Double

    init(request: BgSplitterController.SplitRedoRequest) {
        self.request = request
        _overflow = State(initialValue: request.manifest.overflow)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("この分割をやり直す").font(.title3.bold())

            VStack(alignment: .leading, spacing: 4) {
                Text("元シート")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(URL(fileURLWithPath: request.manifest.source).lastPathComponent)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("はみ出し許容マージン")
                    Spacer()
                    Text(String(format: "%.2f", overflow))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $overflow, in: 0...0.5, step: 0.01)
                Text("値を大きくすると隣のパネルの断片を拾いやすくなる代わりに、キャラの一部が欠けにくくなるよ。小さくすると隣の断片は混ざりにくいけど、髪や装飾がはみ出して切れることがあるよ。前回の値: \(String(format: "%.2f", request.manifest.overflow))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("同じ出力先（このセルと同じフォルダ）に上書きされるよ。モデルは前回と同じ「\(modelDisplayName)」を使うよ。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("キャンセル") {
                    bgSplitter.cancelSplitRedo()
                    dismiss()
                }
                Button("再分割") {
                    bgSplitter.confirmSplitRedo(overflow: overflow)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var modelDisplayName: String {
        BgSplitterModel.all.first(where: { $0.id == request.manifest.model })?.displayName ?? request.manifest.model
    }
}
