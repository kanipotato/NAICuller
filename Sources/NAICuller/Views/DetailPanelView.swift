import SwiftUI
import AppKit
import NAICullerCore

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
        // `HSplitView`直下（このViewはMainWindowViewでHSplitViewの一員として使われている）で
        // ルートのView自体の同一性を画像切り替えのたびに変えてしまうと、HSplitViewが
        // パネル幅をドラッグ後の値ではなく`.frame(idealWidth:)`へ戻してしまう不具合があった
        // （以前は内側のVStackに`.id(image.id)`を付けていたが、それがルート直下に来る構造に
        // なっていたため顕在化した）。画像を切り替えてもViewの同一性自体は変えず、
        // 画像ごとにリセットしたい状態（プロンプト折りたたみ）だけ`onChange`で個別に戻す。
        // 実際に使ってみてのフィードバックで修正：以前は「画像あり」と「未選択」で
        // `if/else`のサブツリーの構造そのものを差し替えていた（VStack+ScrollView ⇔ 素のVStack）。
        // 構造が入れ替わるとHSplitViewがペイン幅を計算し直すため、1枚目を選んだ瞬間に
        // パネルが最大幅(480pt)から最小幅(260pt)へカクッと縮んでいた（実測で確認）。
        // 外側のフレームを揃えるだけでは足りず、**両状態で同じ構造を描く**必要がある。
        // プレビュー枠・Divider・ScrollViewは常に同じ位置に置き、中身だけを差し替える。
        VStack(alignment: .leading, spacing: 0) {
            // プレビューはScrollViewの外に固定表示する（末端まで送った後の弾性スクロールで
            // 提案される高さがフレームごとに微妙に変動し、aspectRatio(.fit)の再計算が連鎖して
            // プレビューが拡大縮小を繰り返す(ガタつく)不具合があったため。ScrollViewの中に
            // 置いたままだと画像の高さがスクロールの揺れに依存してしまう構造そのものが原因なので、
            // 揺れの入力を受けない場所に出すことで根本的に断つ）。
            previewArea
                .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let image = focusedImage {
                        tagSection(image)
                        Divider()
                        systemInfoSection(image)
                        Divider()
                        promptSection(image)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: focusedImage?.id) { _ in
            promptExpanded = false
        }
    }

    /// プレビュー領域。未選択時も同じ場所・同じ横幅の器を描き、パネル幅が選択の有無で
    /// 動かないようにする（上のコメント参照）。
    @ViewBuilder
    private var previewArea: some View {
        if let image = focusedImage {
            previewSection(image)
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.08))
                .frame(maxWidth: .infinity, minHeight: 180)
                .overlay {
                    Text("画像を選択してね")
                        .foregroundStyle(.secondary)
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
                    // ScrollView外の固定表示なので、この上限(仮置き480pt)は純粋に
                    // 「縦長画像でパネルを占領しすぎない」ための安全弁。
                    .frame(maxWidth: .infinity, maxHeight: 480)
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
                Text(failure.message)
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


    // MARK: - 3. システム情報

    @ViewBuilder
    private func systemInfoSection(_ image: ImageRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("システム情報").font(.headline)
            infoRow("パス", image.path) { appModel.copyPath(of: image) }
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

    private func infoRow(_ label: String, _ value: String, copyAction: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(value).font(.caption).textSelection(.enabled)
                if let copyAction {
                    Button(action: copyAction) {
                        Image(systemName: "doc.on.doc")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .help("パスをコピー")
                }
            }
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

    // MARK: - 4. プロンプト / 生成情報（生成元によって出し分け。Stable Diffusion/ComfyUI対応で追加）

    /// アプリ全体のモード切り替えはせず、画像1枚ごとに`sourcePlatform`で出し分ける
    /// （NovelAI/ComfyUIが混在するライブラリでも破綻しない設計。Notion開発ログ参照）。
    @ViewBuilder
    private func promptSection(_ image: ImageRecord) -> some View {
        if image.sourcePlatform == .comfyUI {
            comfyGenerationInfoSection(image)
        } else {
            // .novelAIは「NAIプロンプト」、.unknownは既存通り「プロンプト」（判定できていないので
            // NAI由来と決め打たない）。中身の表示ロジック自体はどちらも同じ。
            naiPromptSection(image, title: image.sourcePlatform == .novelAI ? "NAIプロンプト" : "プロンプト")
        }
    }

    @ViewBuilder
    private func naiPromptSection(_ image: ImageRecord, title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
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

    /// ComfyUI画像の生成情報。ノード種別ごとに抽出・重複除去した内容を並べる。
    /// 1枚のグラフに複数バッチ分のノードが記録されているケースでは複数件になりうる
    /// （実データ調査で確認済み。「見つかった分だけ正直に列挙する」という設計方針）。
    @ViewBuilder
    private func comfyGenerationInfoSection(_ image: ImageRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("生成情報（ComfyUI）").font(.headline)
                Spacer()
                if let rawJSON = image.comfyGenerationInfoJSON {
                    Button {
                        appModel.copyComfyRawJSON(rawJSON)
                    } label: {
                        Label("生JSONをコピー", systemImage: "doc.on.doc")
                    }
                }
            }

            if let rawJSON = image.comfyGenerationInfoJSON,
               let info = ComfyUIWorkflowParser.extractGenerationInfo(from: rawJSON),
               !info.isEmpty {
                comfyGenerationInfoContent(info)
            } else {
                Text("生成情報を読み取れなかったよ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func comfyGenerationInfoContent(_ info: ComfyUIGenerationInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !info.checkpoints.isEmpty {
                comfyInfoGroup("モデル") {
                    ForEach(info.checkpoints, id: \.self) { name in
                        Text(name).font(.caption).textSelection(.enabled)
                    }
                }
            }
            if !info.loras.isEmpty {
                comfyInfoGroup("LoRA（\(info.loras.count)件）") {
                    ForEach(Array(info.loras.enumerated()), id: \.offset) { _, lora in
                        Text("\(lora.name)（model \(Self.formatted(lora.strengthModel))・clip \(Self.formatted(lora.strengthClip))）")
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }
            }
            if !info.promptPairs.isEmpty {
                comfyInfoGroup("プロンプト（\(info.promptPairs.count)件）") {
                    ForEach(Array(info.promptPairs.enumerated()), id: \.offset) { _, pair in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("ポジティブ").font(.caption2).foregroundStyle(.secondary)
                            Text(pair.positive).font(.caption).textSelection(.enabled)
                            Text("ネガティブ").font(.caption2).foregroundStyle(.secondary).padding(.top, 2)
                            Text(pair.negative).font(.caption).textSelection(.enabled)
                        }
                        .padding(.bottom, 4)
                    }
                }
            }
            if !info.samplerParams.isEmpty {
                comfyInfoGroup("サンプラー設定（\(info.samplerParams.count)件）") {
                    ForEach(Array(info.samplerParams.enumerated()), id: \.offset) { _, params in
                        Text("seed \(params.seed) / steps \(params.steps) / cfg \(Self.formatted(params.cfg)) / \(params.samplerName) / \(params.scheduler)")
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func comfyInfoGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            content()
        }
    }

    private static func formatted(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", value) : String(format: "%.2f", value)
    }
}
