import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NAICullerCore

/// メインウィンドウ。サイドバー／サムネイルグリッド／右パネルの3ペイン構成（詳細設計 1章）。
/// `HSplitView`で構成し、右パネルの幅をドラッグでリサイズ可能にする。
struct MainWindowView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var showExifToolMissingAlert = false
    @State private var rootAdditionError: String?
    @State private var showExportPopover = false
    @State private var showShortcutsHelp = false
    @State private var exportFields: Set<ExportFieldKind> = Set(ExportFieldKind.allCases)
    @State private var showPromptCandidatesPopover = false
    @State private var candidateSearchText = ""

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
        // 「削除対象」タグ付き画像のゴミ箱移動確認。完全削除ではなくゴミ箱移動なので復元は可能だが、
        // 予期しない範囲を消さないよう必ず件数を見せてから確認する（他の削除系操作と同じ流儀）。
        .alert("ゴミ箱へ移動しますか？", isPresented: Binding(
            get: { appModel.pendingDeletionScope != nil },
            set: { if !$0 { appModel.cancelDeleteMarkedImages() } }
        )) {
            Button("ゴミ箱へ移動", role: .destructive) { appModel.confirmDeleteMarkedImages() }
            Button("キャンセル", role: .cancel) { appModel.cancelDeleteMarkedImages() }
        } message: {
            Text("「削除対象」タグが付いた画像\(appModel.pendingDeletionCount)件をゴミ箱へ移動します。ゴミ箱からは復元できます。")
        }
        // シート分割のやり直し（余白調整）。isPresented形式のalertだとスライダーを置けないので、
        // 他のモーダルと違いここだけ.sheet(item:)にしている。
        .sheet(item: $appModel.pendingSplitRedo) { request in
            SplitRedoSheetView(request: request)
                .environmentObject(appModel)
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
            // Finderの「表示 > 並び替え」相当。「追加日時」はDBに無いのでmtimeで代用している
            // （ImageSortOrderのコメント参照）。
            Picker("並び替え", selection: $appModel.sortOrder) {
                ForEach(ImageSortOrder.allCases) { order in
                    Text(order.displayName).tag(order)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 170)
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

        // フォーカス中の画像をQuick Lookで大きく表示（実際に使ってみてのフィードバックで追加。
        // 他アプリで開く以外に大きく見る手段が無かった）。スペースキーでも同じ操作ができる。
        ToolbarItem {
            Button {
                appModel.quickLookController.toggle()
            } label: {
                Label("大きく表示", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .disabled(appModel.focusedImageId == nil)
            .help("フォーカス中の画像をQuick Lookで大きく表示（スペースキーでも可）")
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

        // 「削除対象」タグが付いた画像だけをゴミ箱へ移動するメニュー（実際に使ってみての
        // フィードバックで追加）。対象が1件も無ければ押しても意味が無いので無効化しておく。
        ToolbarItem {
            Menu {
                Button("選択中の削除対象を削除...") {
                    appModel.requestDeleteSelectedMarkedImages()
                }
                // コードレビュー指摘の修正：「削除対象を除外」中は削除対象がグリッドから
                // 消えている＝選択にも残らない（refreshFilteredImagesが選択を可視分に
                // 絞り込む）ので、この項目は絶対に成立しない。押せてしまうと
                // 「選択中に削除対象が無いよ」と言われるだけなので、最初から無効化する。
                .disabled(appModel.selectedImageIds.isEmpty || appModel.hideDeletionMarked)
                Button("削除対象を全て削除...") {
                    appModel.requestDeleteAllMarkedImages()
                }
            } label: {
                Label("削除", systemImage: "trash")
            }
            .disabled(deletionMarkCount == 0)
            .help("「削除対象」タグが付いた画像をゴミ箱へ移動する")
        }
    }

    /// 「削除対象」タグが付いている画像の総数（サイドバーのタグ件数表示と同じ集計）。
    private var deletionMarkCount: Int {
        guard let tag = appModel.tags.first(where: { $0.name == Tag.SystemTagName.deletionMark }) else { return 0 }
        return appModel.tagCounts[tag.id] ?? 0
    }

    // MARK: - ショートカット一覧（画面のどこにも表示が無いとの指摘に対応）

    @ViewBuilder
    private var shortcutsHelpContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                // 使い方の要点だけを凝縮して置く（フルの説明は「?」ボタン／Helpメニューの
                // 独立ヘルプウィンドウ側。実際に使ってみてのフィードバックで、作業中にサッと
                // 見るこのポップオーバーと、初見でじっくり読む別ウィンドウの両方を用意した）。
                Text("使い方").font(.headline)
                ForEach(Array(HelpContent.usageSteps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(index + 1).")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(step)
                            .font(.caption)
                    }
                }
                Button {
                    showShortcutsHelp = false
                    openWindow(id: "help")
                } label: {
                    Label("もっと詳しく（ヘルプウィンドウ）", systemImage: "questionmark.circle")
                        .font(.caption)
                }
                .buttonStyle(.link)

                Divider()

                Text("キーボードショートカット").font(.headline)
                ShortcutsListContent()
            }
            .padding()
            .frame(width: 280)
        }
        .frame(maxHeight: 420)
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

    private var tagFilterBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // タグを付ける前の画像は当然まだタグで絞り込めないので、その手前の絞り込み手段として
                // プロンプト本文の部分一致検索を用意した（タグ付け作業の入り口）。
                promptSearchField
                promptCandidatesButton
                // タグ絞り込みでは「付いているもの」しか探せなかったので、その裏返し
                // （まだ手を付けていないもの）を残すためのトグルを追加した。
                Toggle(isOn: $appModel.showUntaggedOnly) {
                    Text("未タグのみ")
                        .font(.caption)
                }
                .toggleStyle(.button)
                .controlSize(.small)
                // ゴミ箱移動待ちの画像がタグ付け作業中もずっとグリッドに残って邪魔、との
                // フィードバックで追加。他の絞り込み条件とは独立して重ねがけできる単純なON/OFF。
                Toggle(isOn: $appModel.hideDeletionMarked) {
                    Text("削除対象を除外")
                        .font(.caption)
                }
                .toggleStyle(.button)
                .controlSize(.small)
            }
            tagChipsRow
            promptTermChipsRow
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - プロンプト候補絞り込み（実際に使ってみてのフィードバックで追加：ルート内に
    // どんなプロンプトがあるか事前に把握していないと、上のプロンプト検索欄に何を打てば
    // いいか分からないため、頻出語句を分析して候補から選べる入り口を用意した）。

    private var promptCandidatesButton: some View {
        Button {
            // 前回の検索語が残っていると、開いた瞬間に理由の分からない絞り込み済み一覧に
            // 見えるのでクリアしてから開く（コードレビュー指摘）。
            candidateSearchText = ""
            appModel.analyzePromptCandidates()
            showPromptCandidatesPopover = true
        } label: {
            Image(systemName: "list.bullet.circle")
        }
        .buttonStyle(.plain)
        .help("有効なルート内のプロンプトを分析し、候補から絞り込む")
        .popover(isPresented: $showPromptCandidatesPopover) {
            promptCandidatesPopover
        }
    }

    @ViewBuilder
    private var promptCandidatesPopover: some View {
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

            TextField("候補を絞り込み", text: $candidateSearchText)
                .textFieldStyle(.roundedBorder)
                .font(.caption)

            if appModel.isAnalyzingPromptCandidates {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if appModel.promptCandidates.isEmpty {
                Text("候補が無いよ（有効なルートにプロンプトが読み込まれた画像が無いかも）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 60)
            } else {
                let candidates = candidateSearchText.isEmpty
                    ? appModel.promptCandidates
                    : appModel.promptCandidates.filter { $0.term.localizedCaseInsensitiveContains(candidateSearchText) }
                // コードレビュー指摘の修正：空判定を絞り込み前の配列にしか掛けていなかったため、
                // 検索語に一致する候補がゼロだと説明の無い空白ペインになっていた。
                if candidates.isEmpty {
                    Text("「\(candidateSearchText)」に一致する候補が無いよ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(candidates) { candidate in
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
                    }
                    .frame(minHeight: 200, maxHeight: 320)
                }
            }
        }
        .padding()
        .frame(width: 300)
    }

    @ViewBuilder
    private var promptTermChipsRow: some View {
        if !appModel.selectedPromptTerms.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(appModel.selectedPromptTerms.sorted(), id: \.self) { term in
                    HStack(spacing: 4) {
                        Text(term)
                            .font(.caption)
                        Button {
                            appModel.selectedPromptTerms.remove(term)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    // タグ絞り込みのチップ（アクセントカラー）と見分けが付くよう別色にする。
                    .background(Capsule().fill(Color.orange.opacity(0.2)))
                }
                Button("すべて解除") {
                    appModel.selectedPromptTerms.removeAll()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var promptSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("プロンプトで絞り込み", text: $appModel.promptSearchText)
                .textFieldStyle(.plain)
                .font(.caption)
            if !appModel.promptSearchText.isEmpty {
                Button {
                    appModel.promptSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        .frame(maxWidth: 280, alignment: .leading)
    }

    @ViewBuilder
    private var tagChipsRow: some View {
        if appModel.showUntaggedOnly {
            HStack {
                Text("未タグの画像のみ表示中")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Spacer(minLength: 0)
            }
        } else if appModel.selectedTagIds.isEmpty {
            HStack {
                Text("タグ絞り込みなし")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Spacer(minLength: 0)
            }
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
