import SwiftUI
import NAICullerCore

/// サブディレクトリ階層フィルタ機能：フォルダツリーの1行（自身を再帰的にネストして描画する）。
/// 3状態チェックボックス（ON/OFF/中間）は`SidebarView.tagRow`と同じ「アイコン＋`onTapGesture`」の
/// 手動実装パターンを踏襲する（SwiftUIの`.toggleStyle(.checkbox)`は2状態しか無いため使えない）。
struct FolderTreeRowView: View {
    @EnvironmentObject private var appModel: AppModel
    let rootId: Int64
    let node: FolderNode
    /// ルート直下ノードにのみ付ける警告アイコン・ツールチップ（旧「ルート」セクションの表示を踏襲）。
    var warning: String?
    var tooltip: String?

    /// ルート直下ノード（`relativePath`が空）は最初から展開、それ以外のサブフォルダは初期折りたたみ。
    @State private var isExpanded: Bool

    init(rootId: Int64, node: FolderNode, warning: String? = nil, tooltip: String? = nil) {
        self.rootId = rootId
        self.node = node
        self.warning = warning
        self.tooltip = tooltip
        _isExpanded = State(initialValue: node.relativePath.isEmpty)
    }

    var body: some View {
        if node.children.isEmpty {
            row
        } else {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(node.children) { child in
                    FolderTreeRowView(rootId: rootId, node: child)
                }
            } label: {
                row
            }
        }
    }

    private var row: some View {
        // レビュー指摘の修正：以前は`checkIconName`と`.off`判定でそれぞれ独立して`checkState`
        // （サブツリー全体を辿る計算プロパティ）を読んでおり、1行の描画につき2回サブツリーを
        // 走査していた。1回だけ求めてここで使い回す。
        let state = checkState
        return HStack {
            Image(systemName: checkIconName(for: state))
                .foregroundStyle(state == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)
            if let warning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(warning)
            }
            Spacer()
            Text("\(node.imageCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // 現在ONなら配下含めて全部OFFに、それ以外(OFF/中間)なら配下含めて全部ONにする
            // （`setFolderVisibility`が配下の個別設定を消してから自身に書き込むため、この1行の
            // 呼び出しだけで配下全体の見た目が新しい状態に揃う）。
            appModel.setFolderVisibility(state != .on, rootId: rootId, node: node)
        }
        .modifier(OptionalHelp(text: tooltip))
    }

    private var checkState: FolderCheckState {
        FolderVisibilityResolver.checkState(for: node, rootId: rootId, overrides: appModel.folderVisibilityOverrides)
    }

    private func checkIconName(for state: FolderCheckState) -> String {
        switch state {
        case .on: return "checkmark.square.fill"
        case .off: return "square"
        case .mixed: return "minus.square.fill"
        }
    }
}

/// `.help(tooltip ?? "")`だと空文字のヘルプが常に付いてしまうため、nilのときは何も付けない分岐を
/// ViewModifierとして切り出す。
private struct OptionalHelp: ViewModifier {
    let text: String?
    func body(content: Content) -> some View {
        if let text {
            content.help(text)
        } else {
            content
        }
    }
}
