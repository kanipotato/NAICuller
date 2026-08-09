import Foundation
import AppKit
import NovelAIViewerCore

/// アプリ全体の状態と、Core層サービスへの窓口をまとめる中心的なObservableObject。
/// SwiftUIビュー群はこれを`@EnvironmentObject`（または直接渡し）で参照する。
///
/// Bundle IDは既存アプリ群（AudioSwitcher/DeskDogs）と同じ`io.github.kanipotato.*`の
/// 命名規則に揃えて`io.github.kanipotato.novelaiviewer`とした
/// （詳細設計は`com.kanipotato.NovelAIViewer`を例示していたが「等、一貫性のある命名で良い」
/// との指示のため、既存アプリの流儀を優先した）。
@MainActor
final class AppModel: ObservableObject {
    static let bundleIdentifier = "io.github.kanipotato.novelaiviewer"

    // MARK: - Core services

    private(set) var db: DatabaseService!
    private(set) var imageRepository: ImageRepository!
    private(set) var tagRepository: TagRepository!
    private(set) var thumbnailService: ThumbnailService!
    private(set) var exportService = ExportService()
    private var exifToolService: ExifToolService?
    private var scanService: ScanService?

    // MARK: - Published state

    @Published private(set) var roots: [Root] = []
    @Published private(set) var rootWarnings: [String: String] = [:] // rootPath -> reason
    @Published private(set) var tags: [Tag] = []
    @Published private(set) var tagCounts: [Int64: Int] = [:]
    @Published private(set) var images: [ImageRecord] = []
    @Published private(set) var imageTagIds: [Int64: Set<Int64>] = [:] // imageId -> tagIds（グリッド/フィルタ用キャッシュ）

    @Published var selectedTagIds: Set<Int64> = []
    /// サイドバーのルートチェックボックスで有効化されているルート（未チェックのルート配下の画像は
    /// グリッドから一時的に除外する。DBからは削除しない表示フィルタ）。
    @Published var enabledRootIds: Set<Int64> = []
    @Published var selectedImageIds: Set<Int64> = []
    @Published var focusedImageId: Int64?
    @Published var thumbnailSize: ThumbnailSize = .medium

    @Published private(set) var exifToolAvailable = false
    @Published private(set) var isScanning = false
    @Published var toastMessage: String?
    @Published var pendingOrphans: [(id: Int64, path: String)] = []
    @Published var showOrphanConfirmation = false

    private var toastDismissTask: Task<Void, Never>?
    /// `toggleTag`が非同期（ExifTool書き込み待ち）の間、同じ(画像, タグ)への二重トグルを
    /// 防ぐための進行中セット（レビュー指摘の修正：キーリピート等で同じキーが連打されると、
    /// 1回目の完了を待たずに2回目が同じ`currentlyTagged`スナップショットを読んでしまい、
    /// add/removeが二重に走りうる）。キーは"\(imageId)-\(tagId)"。
    private var inFlightToggles: Set<String> = []

    // MARK: - 起動

    init() {
        setUpDatabaseAndThumbnailCache()
        recheckExifTool()
        reloadAll()
    }

    private func setUpDatabaseAndThumbnailCache() {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(Self.bundleIdentifier, isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let dbPath = supportDir.appendingPathComponent("db.sqlite").path
        do {
            db = try DatabaseService(path: dbPath)
        } catch {
            // DB初期化自体が失敗した場合は致命的。ダイアログを出して続行不能を伝える
            // （詳細設計 5章：「SQLite書き込み失敗 → エラーダイアログを表示し操作を中断。クラッシュさせない」）。
            presentFatalAlert(message: "DBを開けなかった", informative: "\(error)")
            db = try? DatabaseService(path: ":memory:") // 最低限の続行のため一時的にオンメモリで代替
        }
        imageRepository = ImageRepository(db: db)
        tagRepository = TagRepository(db: db)
        thumbnailService = ThumbnailService(bundleIdentifier: Self.bundleIdentifier)
    }

    /// アプリ終了時に呼ぶ後片付け。常駐させているexiftoolプロセスへ`-stay_open False`を
    /// 送って穏当に終了させる（レビュー指摘の修正：`ExifToolProcess.deinit`はある物の、
    /// 通常のアプリ終了は`NSApplication`が内部で`exit()`する経路のため、その時点で
    /// まだ参照が生きているオブジェクトのdeinitはSwiftランタイムの保証対象外＝
    /// 呼ばれないことがある。`applicationWillTerminate`から明示的にこれを呼ぶことで、
    /// プロセスがオーファンとして残り続けるのを防ぐ）。
    func shutdown() {
        exifToolService?.close()
    }

    /// ExifToolの検出をやり直す（起動時／設定画面の「再チェック」ボタンから呼ぶ）。
    func recheckExifTool() {
        guard let url = ExifToolService.locateExecutable() else {
            exifToolAvailable = false
            exifToolService = nil
            scanService = nil
            return
        }
        do {
            let service = try ExifToolService(executableURL: url)
            exifToolService = service
            scanService = ScanService(imageRepository: imageRepository, tagRepository: tagRepository, exifTool: service)
            exifToolAvailable = true
        } catch {
            exifToolAvailable = false
            exifToolService = nil
            scanService = nil
        }
    }

    // MARK: - 再読み込み

    func reloadAll() {
        reloadRoots()
        reloadTags()
        reloadImages()
    }

    func reloadRoots() {
        let previousIds = Set(roots.map(\.id))
        roots = (try? imageRepository.fetchAllRoots()) ?? []
        let currentIds = Set(roots.map(\.id))
        // 新規に増えたルート（前回時点で知らなかったID）はデフォルト有効にする。
        let newlyAddedIds = currentIds.subtracting(previousIds)
        enabledRootIds.formIntersection(currentIds) // 削除済みルートのIDは外す
        enabledRootIds.formUnion(newlyAddedIds) // 新規ルートを有効化（既存ルートの手動OFFは保持）
    }

    func reloadTags() {
        tags = (try? tagRepository.fetchAll()) ?? []
        tagCounts = (try? tagRepository.tagCounts()) ?? [:]
    }

    func reloadImages() {
        images = (try? imageRepository.fetchImages()) ?? []
        var mapping: [Int64: Set<Int64>] = [:]
        for image in images {
            mapping[image.id] = (try? tagRepository.tagIds(forImage: image.id)) ?? []
        }
        imageTagIds = mapping
    }

    /// サイドバーのルートチェックボックス・タグ絞り込み（AND条件：選択した全タグを持つ画像のみ）を
    /// 適用した結果。グリッド・エクスポート対象はすべてこれを見る。
    var filteredImages: [ImageRecord] {
        images.filter { image in
            guard enabledRootIds.contains(image.rootId) else { return false }
            guard !selectedTagIds.isEmpty else { return true }
            guard let tagIds = imageTagIds[image.id] else { return false }
            return selectedTagIds.isSubset(of: tagIds)
        }
    }

    // MARK: - ルート管理

    func addRoot(path: String) -> RootPathValidator.Failure? {
        if let failure = RootPathValidator.validate(candidatePath: path, existingPaths: roots.map(\.path)) {
            return failure
        }
        do {
            _ = try imageRepository.insertRoot(path: path)
            reloadRoots()
            return nil
        } catch {
            presentAlert(message: "ルートの追加に失敗した", informative: "\(error)")
            return nil
        }
    }

    func removeRoot(id: Int64) {
        do {
            try imageRepository.deleteRoot(id: id)
            reloadAll()
        } catch {
            presentAlert(message: "ルートの削除に失敗した", informative: "\(error)")
        }
    }

    // MARK: - スキャン

    func rescan() {
        guard let scanService, !isScanning else { return }
        isScanning = true
        let targets = roots
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = try? scanService.scan(roots: targets)
            guard let self else { return }
            await MainActor.run {
                self.isScanning = false
                guard let result else {
                    self.presentAlert(message: "スキャンに失敗した", informative: nil)
                    return
                }
                self.rootWarnings = Dictionary(uniqueKeysWithValues: result.warnings.map { ($0.rootPath, $0.reason) })
                for id in result.changedImageIds {
                    self.thumbnailService.invalidate(imageId: id)
                }
                self.reloadAll()
                if !result.orphanImages.isEmpty {
                    self.pendingOrphans = result.orphanImages
                    self.showOrphanConfirmation = true
                }
                self.showToast("スキャン完了: 新規\(result.newImageCount)件・更新\(result.updatedImageCount)件")
            }
        }
    }

    /// 孤児レコードのユーザー確認後の一括削除（自動削除はしない。詳細設計 5章）。
    func confirmDeleteOrphans() {
        let ids = pendingOrphans.map(\.id)
        do {
            try imageRepository.deleteImages(ids: ids)
        } catch {
            presentAlert(message: "孤児レコードの削除に失敗した", informative: "\(error)")
        }
        pendingOrphans = []
        showOrphanConfirmation = false
        reloadAll()
    }

    func dismissOrphanConfirmation() {
        pendingOrphans = []
        showOrphanConfirmation = false
    }

    // MARK: - タグ付け（4-2章：F/G/1-9共通のトグル機構）

    /// タグ付けをトグルする。画像ファイル側への書き込みが成功した場合のみDBを更新する
    /// （詳細設計 4-2章：「ExifTool書き込みが失敗したら？ → DBの状態は変更しない」）。
    func toggleTag(tagId: Int64, on image: ImageRecord) {
        guard let exifToolService else {
            presentAlert(message: "ExifToolが利用できないためタグ付けできない", informative: nil)
            return
        }
        guard let tag = tags.first(where: { $0.id == tagId }) else { return }
        let key = "\(image.id)-\(tagId)"
        // 同じ(画像, タグ)への書き込みが既に進行中なら、キーリピート等による二重トグルとして無視する。
        guard !inFlightToggles.contains(key) else { return }
        inFlightToggles.insert(key)
        let currentlyTagged = imageTagIds[image.id]?.contains(tagId) ?? false

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                if currentlyTagged {
                    try exifToolService.removeTag(tag.name, from: image.path)
                } else {
                    try exifToolService.addTag(tag.name, to: image.path)
                }
                await MainActor.run {
                    do {
                        if currentlyTagged {
                            try self.tagRepository.removeTagFromImage(imageId: image.id, tagId: tagId)
                        } else {
                            try self.tagRepository.addTagToImage(imageId: image.id, tagId: tagId)
                        }
                        self.reloadTags()
                        self.reloadImages()
                    } catch {
                        self.presentAlert(message: "DBの更新に失敗した", informative: "\(error)")
                    }
                    self.inFlightToggles.remove(key)
                }
            } catch {
                await MainActor.run {
                    // 詳細設計 5章：ExifTool書き込み失敗 → トースト通知でファイル名とエラー内容を表示。DBは変更しない。
                    self.showToast("「\(image.url.lastPathComponent)」へのタグ付けに失敗: \(error)")
                    self.inFlightToggles.remove(key)
                }
            }
        }
    }

    /// キー割当（F/G/1〜9）からタグを引いてトグルする。KeyCommandHandlerから呼ばれる。
    func toggleTag(forKey key: String, on image: ImageRecord) {
        guard let tag = tags.first(where: { $0.keyBinding == key }) else { return } // 未設定なら何もしない（4-2章）
        toggleTag(tagId: tag.id, on: image)
    }

    /// 自由入力タグの追加。既存タグがあれば（大文字小文字区別なく）それに紐付け、新規作成しない。
    func addFreeTag(name rawName: String, to image: ImageRecord) {
        guard let normalized = TagNameValidator.normalize(rawName) else { return }
        guard let exifToolService else { return }
        do {
            let tagId: Int64
            if let existing = try tagRepository.fetchByNameCaseInsensitive(normalized) {
                tagId = existing.id
            } else {
                tagId = try tagRepository.insertUserTag(name: normalized)
            }
            let tagName = normalized
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                do {
                    try exifToolService.addTag(tagName, to: image.path)
                    await MainActor.run {
                        try? self.tagRepository.addTagToImage(imageId: image.id, tagId: tagId)
                        self.reloadTags()
                        self.reloadImages()
                    }
                } catch {
                    await MainActor.run {
                        self.showToast("タグ追加に失敗: \(error)")
                    }
                }
            }
        } catch {
            presentAlert(message: "タグの作成に失敗した", informative: "\(error)")
        }
    }

    func removeFreeTag(tagId: Int64, from image: ImageRecord) {
        toggleTag(tagId: tagId, on: image)
    }

    // MARK: - カスタムタグのキー割当（設定画面）

    /// 1〜9キーへのカスタムタグ割当。同じキーへの重複割当は上書き確認が必要
    /// （呼び出し側のUIで確認ダイアログを出した後にこれを呼ぶこと）。
    /// 保存前に呼ぶ：この割当が他の割当を上書きすることになる場合、確認メッセージを返す
    /// （詳細設計 2章：「同じキーへの重複割当は上書き確認」）。nilなら確認不要でそのまま保存してよい。
    func conflictWarning(forKey key: String, name rawName: String) -> String? {
        guard let normalized = TagNameValidator.normalize(rawName) else { return nil }
        var messages: [String] = []
        if let currentAtKey = try? tagRepository.fetchByKeyBinding(key),
           !TagNameValidator.isSameName(currentAtKey.name, normalized) {
            messages.append("キー「\(key)」は現在「\(currentAtKey.name)」に割り当てられています。")
        }
        if let existingByName = try? tagRepository.fetchByNameCaseInsensitive(normalized),
           let boundKey = existingByName.keyBinding, boundKey != key {
            messages.append("タグ「\(normalized)」は現在キー「\(boundKey)」に割り当てられています。")
        }
        guard !messages.isEmpty else { return nil }
        return messages.joined(separator: "\n") + "\n上書きしますか？"
    }

    func assignCustomTag(key: String, name rawName: String) -> TagNameValidator.Failure? {
        guard let normalized = TagNameValidator.normalize(rawName) else {
            return TagNameValidator.validate(rawName) ?? .empty
        }
        do {
            // 同じキーを既に使っているタグがあれば先に外す（UNIQUE制約対策、UI側で上書き確認済みの前提）。
            if let existing = try tagRepository.fetchByKeyBinding(key) {
                try tagRepository.clearKeyBinding(tagId: existing.id)
            }
            if let existingByName = try tagRepository.fetchByNameCaseInsensitive(normalized) {
                try tagRepository.setKeyBinding(tagId: existingByName.id, keyBinding: key)
            } else {
                _ = try tagRepository.insertUserTag(name: normalized, keyBinding: key)
            }
            reloadTags()
            return nil
        } catch {
            presentAlert(message: "キー割当の保存に失敗した", informative: "\(error)")
            return nil
        }
    }

    func clearCustomTag(key: String) {
        guard let existing = try? tagRepository.fetchByKeyBinding(key), !existing.isSystem else { return }
        try? tagRepository.clearKeyBinding(tagId: existing.id)
        reloadTags()
    }

    // MARK: - プロンプトコピー（4-4章）

    func copyPrompt(of image: ImageRecord) {
        guard let prompt = image.promptCache, !prompt.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        showToast("コピーしました")
    }

    // MARK: - エクスポート（4-3章）

    func exportImages(_ images: [ImageRecord], fields: [ExportFieldKind], to url: URL) {
        do {
            try exportService.export(images: images, fields: fields, to: url)
            showToast("\(images.count)件をエクスポートしました")
        } catch {
            presentAlert(message: "エクスポートに失敗した", informative: "\(error)")
        }
    }

    // MARK: - トースト・アラート共通処理

    func showToast(_ message: String, duration: TimeInterval = 2.5) {
        toastMessage = message
        toastDismissTask?.cancel()
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.toastMessage = nil }
        }
    }

    private func presentAlert(message: String, informative: String?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        if let informative { alert.informativeText = informative }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentFatalAlert(message: String, informative: String?) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = message
        if let informative { alert.informativeText = informative }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
