import SwiftUI
import AppKit
import NovelAIViewerCore

/// 右パネル：プレビュー・タグ情報・システム情報・プロンプトの4グループ構成（詳細設計 1章）。
/// 生成AI管理特化ツールのような細かいEXIF風メタデータ一覧は意図的に採用せず、荒めの出力に留める。
struct DetailPanelView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var newTagText = ""
    @State private var showAddTagPopover = false
    @State private var promptExpanded = false
    @State private var previewImage: NSImage?
    @State private var previewLoadedForId: Int64?

    private var focusedImage: ImageRecord? {
        let id = appModel.focusedImageId ?? appModel.selectedImageIds.first
        guard let id else { return nil }
        return appModel.filteredImages.first(where: { $0.id == id })
    }

    var body: some View {
        ScrollView {
            if let image = focusedImage {
                VStack(alignment: .leading, spacing: 16) {
                    previewSection(image)
                    Divider()
                    tagSection(image)
                    Divider()
                    systemInfoSection(image)
                    Divider()
                    promptSection(image)
                }
                .padding()
                .id(image.id)
            } else {
                VStack {
                    Spacer(minLength: 60)
                    Text("画像を選択してね")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - 1. プレビュー画像

    @ViewBuilder
    private func previewSection(_ image: ImageRecord) -> some View {
        Group {
            if previewLoadedForId == image.id, let previewImage {
                Image(nsImage: previewImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 180)
            }
        }
        .task(id: image.id) {
            let path = image.path
            // NSImageはmacOS14未満ではSendable未対応のため、バックグラウンドではData読み込みまでに留め、
            // NSImageの生成はメインアクター側（await復帰後）で行う。
            let data = await Task.detached(priority: .userInitiated) {
                try? Data(contentsOf: URL(fileURLWithPath: path))
            }.value
            guard image.id == focusedImage?.id else { return } // 読み込み中に別画像へ切り替わっていたら破棄
            previewImage = data.flatMap { NSImage(data: $0) }
            previewLoadedForId = image.id
        }
    }

    // MARK: - 2. タグ情報

    @ViewBuilder
    private func tagSection(_ image: ImageRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("タグ").font(.headline)
                Spacer()
                Button {
                    newTagText = ""
                    showAddTagPopover = true
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
                .disabled(!appModel.exifToolAvailable)
                .popover(isPresented: $showAddTagPopover) {
                    addTagPopover(image)
                }
            }

            let currentTagIds = (appModel.imageTagIds[image.id] ?? [])
            let currentTags = appModel.tags.filter { currentTagIds.contains($0.id) }
            if currentTags.isEmpty {
                Text("タグなし")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(currentTags) { tag in
                        HStack(spacing: 4) {
                            Text(tag.name)
                                .font(.caption)
                                .lineLimit(1)
                            Button {
                                appModel.toggleTag(tagId: tag.id, on: image)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption2)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func addTagPopover(_ image: ImageRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("タグを追加").font(.headline)

            let currentTagIds = (appModel.imageTagIds[image.id] ?? [])
            let candidates = appModel.tags.filter { !currentTagIds.contains($0.id) }
            if !candidates.isEmpty {
                Text("既存タグから選ぶ").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(candidates) { tag in
                            Button {
                                appModel.toggleTag(tagId: tag.id, on: image)
                            } label: {
                                Text(tag.name)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 2)
                        }
                    }
                }
                .frame(maxHeight: 120)
                Divider()
            }

            Text("新しいタグ名").font(.caption).foregroundStyle(.secondary)
            TextField("タグ名", text: $newTagText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submitNewTag(image) }

            if !newTagText.isEmpty, let failure = TagNameValidator.validate(newTagText) {
                Text(validationMessage(failure))
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("キャンセル") {
                    showAddTagPopover = false
                    newTagText = ""
                }
                Button("追加") { submitNewTag(image) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(TagNameValidator.normalize(newTagText) == nil)
            }
        }
        .padding()
        .frame(width: 260)
    }

    private func submitNewTag(_ image: ImageRecord) {
        guard TagNameValidator.normalize(newTagText) != nil else { return }
        appModel.addFreeTag(name: newTagText, to: image)
        newTagText = ""
        showAddTagPopover = false
    }

    private func validationMessage(_ failure: TagNameValidator.Failure) -> String {
        switch failure {
        case .empty: return "タグ名を入力してね"
        case .containsControlCharacters: return "改行やタブは使えないよ"
        case .tooLong: return "タグ名は\(TagNameValidator.maxLength)文字以内にしてね"
        }
    }

    // MARK: - 3. システム情報

    @ViewBuilder
    private func systemInfoSection(_ image: ImageRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("システム情報").font(.headline)
            infoRow("パス", image.path)
            if let width = image.width, let height = image.height {
                infoRow("サイズ", "\(width) × \(height)")
            }
            infoRow("ファイルサイズ", ByteCountFormatter.string(fromByteCount: image.fileSize, countStyle: .file))
            if let creationDate = creationDate(for: image.path) {
                infoRow("作成日時", Self.dateFormatter.string(from: creationDate))
            }
            infoRow("最終スキャン", Self.dateFormatter.string(from: image.lastScannedAt))
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption).textSelection(.enabled)
        }
    }

    private func creationDate(for path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.creationDate] as? Date
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: - 4. プロンプト（折りたたみ＋コピー）

    @ViewBuilder
    private func promptSection(_ image: ImageRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("プロンプト").font(.headline)
                Spacer()
                Button {
                    appModel.copyPrompt(of: image)
                } label: {
                    Label("コピー", systemImage: "doc.on.doc")
                }
                // プロンプトが読めなかった画像ではコピーボタンを無効化する（詳細設計 4-4章）。
                .disabled((image.promptCache ?? "").isEmpty)
            }

            if let prompt = image.promptCache, !prompt.isEmpty {
                DisclosureGroup(isExpanded: $promptExpanded) {
                    Text(prompt)
                        .font(.caption)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                } label: {
                    Text(promptExpanded ? "折りたたむ" : "プロンプトを表示（\(prompt.count)文字）")
                        .font(.caption)
                }
            } else {
                Text("プロンプトを読み取れなかったよ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
