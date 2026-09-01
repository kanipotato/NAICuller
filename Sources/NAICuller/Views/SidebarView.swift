import SwiftUI
import NAICullerCore

/// サイドバー：生成元一覧・登録ルートのフォルダツリー（サブディレクトリ階層フィルタ）・
/// タグ一覧（`:`を含むタグは自動グルーピング）。
struct SidebarView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        List {
            // Stable Diffusion(ComfyUI)対応で追加。フラットなSetでON/OFFを持つシンプルな
            // チェックボックス絞り込み（旧「ルート」セクションが使っていたのと同じパターン。
            // 「ルート」セクション自体はその後フォルダツリー化されたため、今はこちらだけがこの形）。
            Section("生成元") {
                ForEach(ImageSourcePlatform.allCases) { platform in
                    HStack {
                        Toggle(isOn: Binding(
                            get: { appModel.enabledSourcePlatforms.contains(platform) },
                            set: { isOn in
                                if isOn { appModel.enabledSourcePlatforms.insert(platform) }
                                else { appModel.enabledSourcePlatforms.remove(platform) }
                            }
                        )) {
                            Text(platform.displayName)
                        }
                        .toggleStyle(.checkbox)
                        Spacer()
                        Text("\(platformCount(platform))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // サブディレクトリ階層フィルタ機能で、旧「ルートのフラットなON/OFFチェックボックス」から
            // VSCode風の展開可能なフォルダツリーに置き換えた（ルート直下ノードが旧enabledRootIdsと
            // 同じ役割を果たす）。
            Section("ルート") {
                ForEach(appModel.roots) { root in
                    if let tree = appModel.folderTrees[root.id] {
                        FolderTreeRowView(
                            rootId: root.id,
                            node: tree,
                            warning: appModel.rootWarnings[root.path],
                            tooltip: root.path
                        )
                    }
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

    /// 生成元ごとの画像枚数（フィルタ前の全件が対象。タグ件数表示と同じ「絞り込みの外側の全体数」）。
    private func platformCount(_ platform: ImageSourcePlatform) -> Int {
        appModel.images.lazy.filter { $0.sourcePlatform == platform }.count
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
