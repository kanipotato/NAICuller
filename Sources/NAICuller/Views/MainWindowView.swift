import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NAICullerCore

/// メインウィンドウ。サイドバー／サムネイルグリッド／右パネルの3ペイン構成（詳細設計 1章）。
/// `HSplitView`で構成し、右パネルの幅をドラッグでリサイズ可能にする。
struct MainWindowView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var showExifToolMissingAlert = false
    @State private var rootAdditionError: String?
    @State private var showExportPopover = false
    @State private var showShortcutsHelp = false
    @State private var exportFields: Set<ExportFieldKind> = Set(ExportFieldKind.allCases)

    var body: some View {
        HSplitView {
            SidebarView()
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)

            VStack(spacing: 0) {
                // タグ絞り込みの現在地表示。以前はツールバーの`.principal`(中央固定)に
                // 置いていたが、中央揃え・丸いピル表示が見づらいとの指摘を受けて、
                // グリッド上部に左寄せで移動した。フィルタが増えても折り返して
                // 縦に伸びるだけで横にはみ出さないよう`FlowLayout`で並べる。
                tagFilterBar
                Divider()
                ThumbnailGridView()
            }
            .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)

            DetailPanelView()
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 480)
        }
        .toolbar { toolbarContent }
        .overlay(alignment: .bottom) { toastOverlay }
        .onAppear {
            if !appModel.exifToolAvailable {
                showExifToolMissingAlert = true
            }
        }
        // ExifTool未検出時の案内モーダル（詳細設計 5章）。
        .alert("ExifToolが必要です", isPresented: $showExifToolMissingAlert) {
            Button("再チェック") {
                appModel.recheckExifTool()
                showExifToolMissingAlert = !appModel.exifToolAvailable
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text("ターミナルで `brew install exiftool` を実行してインストールしてから「再チェック」を押してね。スキャン・タグ付け機能はインストールされるまで使えません。")
        }
        // 孤児レコード確認（詳細設計 5章：自動削除はしない）。
        .alert("見つからなくなった画像があります", isPresented: $appModel.showOrphanConfirmation) {
            Button("削除", role: .destructive) { appModel.confirmDeleteOrphans() }
            Button("キャンセル", role: .cancel) { appModel.dismissOrphanConfirmation() }
        } message: {
            Text("ファイルシステム上に見つからない画像が\(appModel.pendingOrphans.count)件あります。DBの記録を削除しますか？（画像ファイル自体には触れません）")
        }
        .alert("ルートを追加できません", isPresented: Binding(
            get: { rootAdditionError != nil },
            set: { if !$0 { rootAdditionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(rootAdditionError ?? "")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                chooseRoot()
            } label: {
                Label("ルート追加", systemImage: "folder.badge.plus")
            }
            .disabled(!appModel.exifToolAvailable)
        }

        ToolbarItem {
            HStack(spacing: 6) {
                Image(systemName: "photo")
                    .font(.caption)
                Slider(
                    value: Binding(
                        get: { Double(appModel.thumbnailSize.rawValue) },
                        set: { appModel.thumbnailSize = ThumbnailSize(rawValue: Int($0.rounded())) ?? .medium }
                    ),
                    in: 0...Double(ThumbnailSize.allCases.count - 1),
                    step: 1
                )
                .frame(width: 120)
                Image(systemName: "photo.fill")
                    .font(.body)
            }
        }

        ToolbarItem {
            Button {
                appModel.rescan()
            } label: {
                if appModel.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Label("再スキャン", systemImage: "arrow.clockwise")
                }
            }
            .disabled(!appModel.exifToolAvailable || appModel.isScanning || appModel.roots.isEmpty)
        }

        ToolbarItem {
            Button {
                showExportPopover = true
            } label: {
                Label("エクスポート", systemImage: "square.and.arrow.up")
            }
            .disabled(appModel.selectedImageIds.isEmpty)
            .popover(isPresented: $showExportPopover) {
                exportPopoverContent
            }
        }

        ToolbarItem {
            Button {
                showShortcutsHelp = true
            } label: {
                Label("ショートカット", systemImage: "keyboard")
            }
            .help("キーボードショートカット一覧")
            .popover(isPresented: $showShortcutsHelp) {
                shortcutsHelpContent
            }
        }
    }

    // MARK: - ショートカット一覧（画面のどこにも表示が無いとの指摘に対応）

    @ViewBuilder
    private var shortcutsHelpContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("キーボードショートカット").font(.headline)

            shortcutRow("← → / ↑ ↓", "前後の画像へ移動（プレビュー維持）")
            Divider()
            shortcutRow("F", "お気に入り（トグル）")
            shortcutRow("G", "削除対象としてマーク（トグル）")
            Divider()
            Text("カスタムタグ（設定 > キー割当で変更）")
                .font(.caption)
                .foregroundStyle(.secondary)
            let customTagRows = appModel.tags
                .filter { $0.keyBinding.flatMap(Int.init) != nil }
                .sorted { ($0.keyBinding ?? "") < ($1.keyBinding ?? "") }
            if customTagRows.isEmpty {
                Text("未設定だよ")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(customTagRows) { tag in
                    shortcutRow(tag.keyBinding ?? "", tag.name)
                }
            }
        }
        .padding()
        .frame(width: 260)
    }

    private func shortcutRow(_ key: String, _ description: String) -> some View {
        HStack(alignment: .top) {
            Text(key)
                .font(.caption.monospaced())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            Text(description)
                .font(.caption)
            Spacer()
        }
    }

    // MARK: - エクスポート（詳細設計 4-3章：項目チェックボックス最低1つ必須、NSSavePanelで保存先選択）

    @ViewBuilder
    private var exportPopoverContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("エクスポート項目").font(.headline)
            ForEach(ExportFieldKind.allCases) { field in
                Toggle(isOn: Binding(
                    get: { exportFields.contains(field) },
                    set: { isOn in
                        if isOn { exportFields.insert(field) } else { exportFields.remove(field) }
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
                    .disabled(exportFields.isEmpty)
            }
        }
        .padding()
        .frame(width: 260)
    }

    private func performExport() {
        let selectedImages = appModel.filteredImages.filter { appModel.selectedImageIds.contains($0.id) }
        guard !selectedImages.isEmpty, !exportFields.isEmpty else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = ExportService.defaultFileName()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let orderedFields = ExportFieldKind.allCases.filter { exportFields.contains($0) }
        appModel.exportImages(selectedImages, fields: orderedFields, to: url)
        showExportPopover = false
    }

    @ViewBuilder
    private var tagFilterBar: some View {
        if appModel.selectedTagIds.isEmpty {
            HStack {
                Text("絞り込みなし")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        } else {
            FlowLayout(spacing: 6) {
                ForEach(appModel.tags.filter { appModel.selectedTagIds.contains($0.id) }) { tag in
                    HStack(spacing: 4) {
                        Text(tag.name)
                            .font(.caption)
                        Button {
                            appModel.selectedTagIds.remove(tag.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                }
                Button("すべて解除") {
                    appModel.selectedTagIds.removeAll()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let message = appModel.toastMessage {
            Text(message)
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 16)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .animation(.easeInOut(duration: 0.2), value: appModel.toastMessage)
        }
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "追加"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let failure = appModel.addRoot(path: url.path) {
            rootAdditionError = describe(failure)
        } else {
            appModel.rescan()
        }
    }

    private func describe(_ failure: RootPathValidator.Failure) -> String {
        switch failure {
        case .notExisting:
            return "指定したパスが存在しません。"
        case .notDirectory:
            return "指定したパスはディレクトリではありません。"
        case .duplicateOrContained(let existingPath):
            return "既存のルート「\(existingPath)」と重複しているか、包含関係にあります。"
        }
    }
}

/// サイドバー：登録ルート一覧（チェックボックス）・タグ一覧（`:`を含むタグは自動グルーピング）。
private struct SidebarView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        List {
            Section("ルート") {
                ForEach(appModel.roots) { root in
                    HStack {
                        Toggle(isOn: Binding(
                            get: { appModel.enabledRootIds.contains(root.id) },
                            set: { isOn in
                                if isOn { appModel.enabledRootIds.insert(root.id) }
                                else { appModel.enabledRootIds.remove(root.id) }
                            }
                        )) {
                            Text((root.path as NSString).lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .toggleStyle(.checkbox)
                        if appModel.rootWarnings[root.path] != nil {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help(appModel.rootWarnings[root.path] ?? "")
                        }
                    }
                    .help(root.path)
                }
            }

            Section("タグ") {
                ForEach(groupedTags, id: \.id) { group in
                    if let title = group.title {
                        DisclosureGroup(title) {
                            ForEach(group.tags) { tag in
                                tagRow(tag, displayName: suffix(of: tag, prefix: title))
                            }
                        }
                    } else {
                        ForEach(group.tags) { tag in
                            tagRow(tag, displayName: tag.name)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func tagRow(_ tag: Tag, displayName: String) -> some View {
        HStack {
            Image(systemName: appModel.selectedTagIds.contains(tag.id) ? "checkmark.square.fill" : "square")
                .foregroundStyle(appModel.selectedTagIds.contains(tag.id) ? Color.accentColor : .secondary)
            Text(displayName)
            Spacer()
            Text("\(appModel.tagCounts[tag.id] ?? 0)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if appModel.selectedTagIds.contains(tag.id) {
                appModel.selectedTagIds.remove(tag.id)
            } else {
                appModel.selectedTagIds.insert(tag.id)
            }
        }
    }

    private func suffix(of tag: Tag, prefix: String) -> String {
        guard tag.name.hasPrefix(prefix + ":") else { return tag.name }
        return String(tag.name.dropFirst(prefix.count + 1))
    }

    private struct TagGroup: Identifiable {
        let id: String
        let title: String?
        let tags: [Tag]
    }

    private var groupedTags: [TagGroup] {
        let grouped = Dictionary(grouping: appModel.tags) { $0.categoryPrefix }
        var groups: [TagGroup] = []
        if let ungrouped = grouped[nil] {
            groups.append(TagGroup(id: "__ungrouped__", title: nil, tags: ungrouped))
        }
        let prefixedKeys = grouped.keys.compactMap { $0 }.sorted()
        for prefix in prefixedKeys {
            groups.append(TagGroup(id: prefix, title: prefix, tags: grouped[prefix] ?? []))
        }
        return groups
    }
}

/// タグ絞り込みチップを左寄せで並べ、幅が足りなくなったら折り返す。
/// 絞り込み条件が増えても横にはみ出さず、縦に伸びて全件表示されるようにするための
/// 最小限のフローレイアウト（SwiftUIの`Layout`プロトコル、macOS13+で利用可能）。
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : rowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
