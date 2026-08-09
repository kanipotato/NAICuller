import SwiftUI
import AppKit
import NovelAIViewerCore

/// メインウィンドウ。サイドバー／サムネイルグリッド／右パネルの3ペイン構成（詳細設計 1章）。
/// `HSplitView`で構成し、右パネルの幅をドラッグでリサイズ可能にする。
struct MainWindowView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var showExifToolMissingAlert = false
    @State private var rootAdditionError: String?

    var body: some View {
        HSplitView {
            SidebarView()
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)

            ThumbnailGridView()
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

        ToolbarItem(placement: .principal) {
            tagFilterIndicator
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
    }

    @ViewBuilder
    private var tagFilterIndicator: some View {
        if appModel.selectedTagIds.isEmpty {
            Text("絞り込みなし")
                .foregroundStyle(.secondary)
                .font(.caption)
        } else {
            HStack(spacing: 4) {
                ForEach(appModel.tags.filter { appModel.selectedTagIds.contains($0.id) }) { tag in
                    Text(tag.name)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                }
                Button {
                    appModel.selectedTagIds.removeAll()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
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
