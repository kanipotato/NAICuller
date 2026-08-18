import SwiftUI
import NAICullerCore

/// プロンプト候補絞り込みの入口ボタンと、その候補一覧ポップオーバー。
///
/// 実際に使ってみてのフィードバックで追加した機能：ルート内にどんなプロンプトがあるか
/// 事前に把握していないと、隣のプロンプト検索欄に何を打てばいいか分からないため、
/// 頻出語句を分析して候補から選べる入り口を用意した。
///
/// `MainWindowView`から切り出した理由は、ここでしか使わない`@State`（ポップオーバーの
/// 開閉フラグと候補の絞り込み文字列）が親に置かれたままだったため。
struct PromptCandidatesButton: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var showPopover = false
    @State private var searchText = ""

    var body: some View {
        Button {
            // 前回の検索語が残っていると、開いた瞬間に理由の分からない絞り込み済み一覧に
            // 見えるのでクリアしてから開く（コードレビュー指摘）。
            searchText = ""
            appModel.analyzePromptCandidates()
            showPopover = true
        } label: {
            Image(systemName: "list.bullet.circle")
        }
        .buttonStyle(.plain)
        .help("有効なルート内のプロンプトを分析し、候補から絞り込む")
        .popover(isPresented: $showPopover) {
            popoverContent
        }
    }

    @ViewBuilder
    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("プロンプト候補").font(.headline)
                Spacer()
                Button {
                    appModel.analyzePromptCandidates()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("有効なルートの内容を元に再分析")
            }
            Text("有効なルート内の画像プロンプトを分析した候補だよ（2件以上の画像に登場した語句のみ、多い順）")
                .font(.caption2)
                .foregroundStyle(.secondary)

            TextField("候補を絞り込み", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .font(.caption)

            candidateList
        }
        .padding()
        .frame(width: 300)
    }

    @ViewBuilder
    private var candidateList: some View {
        if appModel.isAnalyzingPromptCandidates {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 120)
        } else if appModel.promptCandidates.isEmpty {
            Text("候補が無いよ（有効なルートにプロンプトが読み込まれた画像が無いかも）")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minHeight: 60)
        } else {
            let candidates = filteredCandidates
            // コードレビュー指摘の修正：空判定を絞り込み前の配列にしか掛けていなかったため、
            // 検索語に一致する候補がゼロだと説明の無い空白ペインになっていた。
            if candidates.isEmpty {
                Text("「\(searchText)」に一致する候補が無いよ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(candidates) { candidate in
                            candidateToggle(candidate)
                        }
                    }
                }
                .frame(minHeight: 200, maxHeight: 320)
            }
        }
    }

    private var filteredCandidates: [PromptCandidate] {
        guard !searchText.isEmpty else { return appModel.promptCandidates }
        return appModel.promptCandidates.filter { $0.term.localizedCaseInsensitiveContains(searchText) }
    }

    private func candidateToggle(_ candidate: PromptCandidate) -> some View {
        Toggle(isOn: Binding(
            get: { appModel.selectedPromptTerms.contains(candidate.term) },
            set: { isOn in
                if isOn {
                    appModel.selectedPromptTerms.insert(candidate.term)
                } else {
                    appModel.selectedPromptTerms.remove(candidate.term)
                }
            }
        )) {
            HStack {
                Text(candidate.term)
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                Text("\(candidate.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
    }
}
