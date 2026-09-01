import AppKit
import Foundation
import NAICullerCore

// 「削除対象」タグが付いた画像の一括移動。
//
// 元は AppModel 本体に179行のブロックとして置かれていて、AppModel が1000行を超える
// 主因の1つになっていた。移動先の決定・確認ダイアログの下ごしらえ・実際のファイル移動・
// DBとサムネイルキャッシュの後始末までが1つのまとまりなので、extension として
// このファイルへ切り出す。
//
// AppModel の状態（images / selectedImageIds / repositories）と密に結びついているため、
// BgSplitterController のような独立した ObservableObject にはしていない。
// 別オブジェクトにすると @Published の変更が親へ伝播しない問題を持ち込むだけで、
// 結合は減らないため（対象画像の抽出だけは純粋関数 MarkedImageSelector として
// Core 層へ出し、テストで固定してある）。

extension AppModel {
        // MARK: - 削除対象タグの一括移動（実際に使ってみてのフィードバックで追加）
    //
    // ドラフト段階の設計方針「アプリはファイルシステムに破壊的操作をしない」から意図的に外れる
    // 例外。ドラフトの「懸念・未解決」でも「ゴミ箱移動(NSWorkspace.recycle)は初版スコープ外。
    // 将来必要なら追加検討」と明記していた、その"将来"が実際に来た形。事故を避けるため、
    // 完全削除は一切せず、対象は常に「削除対象タグが付いている画像」だけに厳密に絞る
    // （選択に紛れ込んだ未タグの画像は対象外として黙って除外する）。移動先は「ゴミ箱」（復元可能）
    // か「ユーザーが選んだバックアップフォルダ」の2択（実際に使ってみての要望：「何かに使うかも
    // しれないから完全に消したくない、バックアップフォルダへ移動したい」で追加）。

    /// 選択中の画像のうち「削除対象」タグが付いているものだけを数え、確認ダイアログの表示を要求する。
    /// 実際の移動はconfirmPendingDeletion()を呼ぶまで実行しない。
    func requestMoveSelectedMarkedImages(to destination: DeletionDestination) {
        let targets = selectedMarkedImages()
        guard !targets.isEmpty else {
            showToast("選択中に「削除対象」タグの画像が無いよ")
            return
        }
        pendingDeletionCount = targets.count
        pendingDeletion = PendingDeletion(scope: .selected, destination: destination)
    }

    /// ライブラリ全体で「削除対象」タグが付いている画像（選択状態やフィルタとは無関係）を数え、
    /// 確認ダイアログの表示を要求する。
    func requestMoveAllMarkedImages(to destination: DeletionDestination) {
        let targets = allMarkedImages()
        guard !targets.isEmpty else {
            showToast("「削除対象」タグの画像が無いよ")
            return
        }
        pendingDeletionCount = targets.count
        pendingDeletion = PendingDeletion(scope: .all, destination: destination)
    }

    /// バックアップフォルダを選ぶダイアログを出し、選ばれたら移動を要求する
    /// （確認ダイアログはこの後`pendingDeletion`経由で別途出る）。キャンセル時は何もしない。
    func chooseBackupFolderAndRequestMove(scope: DeletionScope) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "選択"
        panel.message = "移動先のバックアップフォルダを選んでね"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        switch scope {
        case .selected: requestMoveSelectedMarkedImages(to: .backupFolder(url))
        case .all: requestMoveAllMarkedImages(to: .backupFolder(url))
        }
    }

    func confirmPendingDeletion() {
        guard let pending = pendingDeletion else { return }
        let targets = pending.scope == .selected ? selectedMarkedImages() : allMarkedImages()
        pendingDeletion = nil
        switch pending.destination {
        case .trash:
            performTrashDeletion(targets)
        case .backupFolder(let url):
            performBackupMove(targets, to: url)
        }
    }

    func cancelPendingDeletion() {
        pendingDeletion = nil
    }

    /// AppModel本体の`selectedTagIds`/`hideDeletionMarked`のdidSetからも参照するため internal。
    /// （同じ型のextensionだがファイルが分かれているため private にはできない）
    func deletionMarkTagId() -> Int64? {
        tags.first(where: { $0.name == Tag.SystemTagName.deletionMark })?.id
    }

    /// 「削除対象」タグが付いている画像IDの集合。取得に失敗したら空（＝対象なし扱い）にして、
    /// 誤って全件を対象にしてしまわないようにする。
    func deletionMarkedIds() -> Set<Int64> {
        guard let tagId = deletionMarkTagId() else { return [] }
        return Set((try? tagRepository.imageIds(taggedWith: tagId)) ?? [])
    }

    func selectedMarkedImages() -> [ImageRecord] {
        MarkedImageSelector.selected(
            from: images, markedIds: deletionMarkedIds(), selectedIds: selectedImageIds
        )
    }

    func allMarkedImages() -> [ImageRecord] {
        MarkedImageSelector.all(from: images, markedIds: deletionMarkedIds())
    }

    /// 実際にゴミ箱へ移動する（`NSWorkspace.recycle`。完全削除ではなく復元可能な移動）。
    /// 移動に成功したものだけDBレコードを削除する（ExifTool書き込みの成否でDB更新を判断する
    /// 既存のタグ付けロジックと同じ考え方：ファイル操作が実際に成功した分だけ反映する）。
    private func performTrashDeletion(_ targets: [ImageRecord]) {
        guard !targets.isEmpty else { return }
        let urls = targets.map(\.url)
        NSWorkspace.shared.recycle(urls) { [weak self] newURLs, error in
            DispatchQueue.main.async {
                guard let self else { return }
                // 元URLと返却キーの表記ゆれ（シンボリックリンク解決・パス正規化）を吸収する
                // 突き合わせは、実バグを踏んだ箇所なのでCore層のTrashResultReconcilerに
                // 切り出してテストで固定してある。
                let succeededTargets = TrashResultReconciler.succeeded(
                    targets: targets,
                    recycledOriginalURLs: newURLs.keys
                )
                let failedCount = targets.count - succeededTargets.count
                if !succeededTargets.isEmpty {
                    do {
                        try self.imageRepository.deleteImages(ids: succeededTargets.map(\.id))
                    } catch {
                        self.presentAlert(message: "DBレコードの削除に失敗した", informative: "\(error)")
                    }
                    for image in succeededTargets {
                        self.thumbnailService.invalidate(imageId: image.id)
                    }
                    self.selectedImageIds.subtract(Set(succeededTargets.map(\.id)))
                }
                self.reloadAll()
                if failedCount == 0 {
                    self.showToast("\(succeededTargets.count)件をゴミ箱へ移動したよ")
                } else {
                    self.presentAlert(
                        message: "一部の移動に失敗した",
                        informative: "\(succeededTargets.count)件成功・\(failedCount)件失敗。\(error.map { "\($0)" } ?? "")"
                    )
                }
            }
        }
    }

    /// 実際にバックアップフォルダへ移動する（`FileManager.moveItem`）。同名ファイルが既に
    /// 移動先にあっても上書きせず、`UniqueFileNaming`で連番を付けて回避する（Finderの
    /// 「コピー - ファイル名 2.png」と同じ考え方）。移動はディスクI/Oを伴うため
    /// メインスレッドをブロックしないよう`Task.detached`で行う（`rescan()`と同じ方針）。
    /// 移動に成功したものだけDBレコードを削除する（トラッシュ移動と同じ考え方）。
    private func performBackupMove(_ targets: [ImageRecord], to folderURL: URL) {
        guard !targets.isEmpty else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let fileManager = FileManager.default
            var existingNames = Set((try? fileManager.contentsOfDirectory(atPath: folderURL.path)) ?? [])
            var succeededTargets: [ImageRecord] = []
            var failedNames: [String] = []
            for image in targets {
                let destinationURL = UniqueFileNaming.uniqueDestinationURL(
                    for: image.url, in: folderURL, existingNames: existingNames
                )
                do {
                    try fileManager.moveItem(at: image.url, to: destinationURL)
                    existingNames.insert(destinationURL.lastPathComponent)
                    succeededTargets.append(image)
                } catch {
                    failedNames.append(image.url.lastPathComponent)
                }
            }
            // `var`のままTask.detachedとMainActor.runの2クロージャに跨って参照すると
            // Swift 6の厳格な並行性チェックで警告になるため、`let`に固定してから渡す
            // （一括タグ付けの`toggleTag(tagId:on:[ImageRecord])`と同じ対応）。
            let finalSucceededTargets = succeededTargets
            let finalFailedNames = failedNames
            await MainActor.run {
                if !finalSucceededTargets.isEmpty {
                    do {
                        try self.imageRepository.deleteImages(ids: finalSucceededTargets.map(\.id))
                    } catch {
                        self.presentAlert(message: "DBレコードの削除に失敗した", informative: "\(error)")
                    }
                    for image in finalSucceededTargets {
                        self.thumbnailService.invalidate(imageId: image.id)
                    }
                    self.selectedImageIds.subtract(Set(finalSucceededTargets.map(\.id)))
                }
                self.reloadAll()
                if finalFailedNames.isEmpty {
                    self.showToast("\(finalSucceededTargets.count)件をバックアップフォルダへ移動したよ")
                } else {
                    self.presentAlert(
                        message: "一部の移動に失敗した",
                        informative: "\(finalSucceededTargets.count)件成功・\(finalFailedNames.count)件失敗。\(FailureSummary.text(names: finalFailedNames))"
                    )
                }
            }
        }
    }
}
