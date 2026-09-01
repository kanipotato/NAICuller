import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NAICullerCore

/// メインウィンドウ。サイドバー／サムネイルグリッド／右パネルの3ペイン構成（詳細設計 1章）。
/// `HSplitView`で構成し、右パネルの幅をドラッグでリサイズ可能にする。
struct MainWindowView: View {
    @EnvironmentObject private var appModel: AppModel
    /// 分割やり直しシートの提示のみに使う。AppModelのネストではなく直接観測しないと
    /// `pendingSplitRedo`の変化でシートが開かない。
    @EnvironmentObject private var bgSplitter: BgSplitterController
    @State private var showExifToolMissingAlert = false
    @State private var rootAdditionError: String?

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
        // 「削除対象」タグ付き画像の移動確認（ゴミ箱／バックアップフォルダの2択）。
        // 完全削除は一切しないが、予期しない範囲を動かさないよう必ず件数を見せてから確認する
        // （他の削除系操作と同じ流儀）。
        .alert(deletionAlertTitle, isPresented: Binding(
            get: { appModel.pendingDeletion != nil },
            set: { if !$0 { appModel.cancelPendingDeletion() } }
        )) {
            Button(deletionConfirmButtonTitle, role: .destructive) { appModel.confirmPendingDeletion() }
            Button("キャンセル", role: .cancel) { appModel.cancelPendingDeletion() }
        } message: {
            Text(deletionAlertMessage)
        }
        // シート分割のやり直し（余白調整）。isPresented形式のalertだとスライダーを置けないので、
        // 他のモーダルと違いここだけ.sheet(item:)にしている。
        .sheet(item: $bgSplitter.pendingSplitRedo) { request in
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
            ExportToolbarButton()
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
            ShortcutsHelpButton()
        }

        // 「削除対象」タグが付いた画像だけを移動するメニュー（実際に使ってみてのフィードバックで
        // 追加）。移動先はゴミ箱／バックアップフォルダの2択（「何かに使うかもしれないから完全に
        // 消したくない」という要望で追加）。対象が1件も無ければ押しても意味が無いので無効化しておく。
        ToolbarItem {
            Menu {
                Menu("選択中の削除対象を移動") {
                    Button("ゴミ箱へ") { appModel.requestMoveSelectedMarkedImages(to: .trash) }
                    Button("バックアップフォルダへ...") { appModel.chooseBackupFolderAndRequestMove(scope: .selected) }
                }
                // コードレビュー指摘の修正：「削除対象を除外」中は削除対象がグリッドから
                // 消えている＝選択にも残らない（refreshFilteredImagesが選択を可視分に
                // 絞り込む）ので、この項目は絶対に成立しない。押せてしまうと
                // 「選択中に削除対象が無いよ」と言われるだけなので、最初から無効化する。
                .disabled(appModel.selectedImageIds.isEmpty || appModel.hideDeletionMarked)
                Menu("削除対象を全て移動") {
                    Button("ゴミ箱へ") { appModel.requestMoveAllMarkedImages(to: .trash) }
                    Button("バックアップフォルダへ...") { appModel.chooseBackupFolderAndRequestMove(scope: .all) }
                }
            } label: {
                Label("削除", systemImage: "trash")
            }
            .disabled(deletionMarkCount == 0)
            .help("「削除対象」タグが付いた画像をゴミ箱またはバックアップフォルダへ移動する")
        }
    }

    private var deletionAlertTitle: String {
        switch appModel.pendingDeletion?.destination {
        case .backupFolder: return "バックアップフォルダへ移動しますか？"
        case .trash, nil: return "ゴミ箱へ移動しますか？"
        }
    }

    private var deletionConfirmButtonTitle: String {
        switch appModel.pendingDeletion?.destination {
        case .backupFolder: return "移動"
        case .trash, nil: return "ゴミ箱へ移動"
        }
    }

    private var deletionAlertMessage: String {
        switch appModel.pendingDeletion?.destination {
        case .backupFolder(let url):
            return "「削除対象」タグが付いた画像\(appModel.pendingDeletionCount)件を「\(url.lastPathComponent)」へ移動します。"
        case .trash, nil:
            return "「削除対象」タグが付いた画像\(appModel.pendingDeletionCount)件をゴミ箱へ移動します。ゴミ箱からは復元できます。"
        }
    }

    /// 「削除対象」タグが付いている画像の総数（サイドバーのタグ件数表示と同じ集計）。
    private var deletionMarkCount: Int {
        guard let tag = appModel.tags.first(where: { $0.name == Tag.SystemTagName.deletionMark }) else { return 0 }
        return appModel.tagCounts[tag.id] ?? 0
    }

    private var tagFilterBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // タグを付ける前の画像は当然まだタグで絞り込めないので、その手前の絞り込み手段として
                // プロンプト本文の部分一致検索を用意した（タグ付け作業の入り口）。
                promptSearchField
                PromptCandidatesButton()
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
        rootAdditionError = appModel.chooseAndAddRoot()
    }

}
