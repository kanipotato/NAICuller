import AppKit
import Foundation
import NAICullerCore

// タグ付け（4-2章：F/G/1-9共通のトグル機構）。
//
// 元は AppModel 本体に178行のブロックとして置かれており、削除対象の一括移動と並んで
// AppModel が1000行を超える主因になっていた。単体トグル・一括トグル・自由入力タグの
// 追加/削除が1つのまとまりなので、extension としてこのファイルへ切り出す。
//
// 一括トグルの「全員がタグを持っていれば外す、1件でも未タグなら全員に付ける」という
// トライステート判定は、既に純粋関数 BatchTagToggle として Core 層にありテスト済み。
// ここに残るのは ExifTool への書き込みと DB 更新の調整（書き込みが成功した分だけ
// DB を更新する、という 4-2章 の方針）。

extension AppModel {
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
    /// 複数選択中は選択中の全画像に一括適用する。
    func toggleTag(forKey key: String, on images: [ImageRecord]) {
        guard let tag = tags.first(where: { $0.keyBinding == key }) else { return } // 未設定なら何もしない（4-2章）
        toggleTag(tagId: tag.id, on: images)
    }

    /// 複数選択がある場合の一括タグ付け（実際に使ってみてのフィードバックを受けて追加。
    /// 詳細設計では「複数選択時の一括タグ付け」をMVP外としていたが、キーボード操作の
    /// 自然な延長として必要だった）。
    ///
    /// Photos.app等と同じトライステート方式：選択中の全画像が既にタグを持っていれば全て外す、
    /// そうでなければ（1件でも未タグがあれば）全てに付ける。1枚だけの選択は単体版と同じ挙動になる
    /// （単体版のガード・エラー表示をそのまま再利用するため、1枚のときはそちらに委譲する）。
    func toggleTag(tagId: Int64, on images: [ImageRecord]) {
        guard !images.isEmpty else { return }
        guard images.count > 1 else {
            toggleTag(tagId: tagId, on: images[0])
            return
        }
        guard let exifToolService else {
            presentAlert(message: "ExifToolが利用できないためタグ付けできない", informative: nil)
            return
        }
        guard let tag = tags.first(where: { $0.id == tagId }) else { return }

        // トライステートの判断（付けるか外すか・どれを触るか）は純粋ロジックとして
        // Core層のBatchTagToggleに切り出してある。
        let plan = BatchTagToggle.plan(images: images, tagId: tagId, imageTagIds: imageTagIds)
        guard !plan.isNoOp else { return }
        let shouldAdd = plan.shouldAdd
        let targets = plan.targets

        let keys = targets.map { "\($0.id)-\(tagId)" }
        guard keys.allSatisfy({ !inFlightToggles.contains($0) }) else { return }
        inFlightToggles.formUnion(keys)

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var writeSucceeded: [Int64] = []
            var writeFailed: [String] = []
            for image in targets {
                do {
                    if shouldAdd {
                        try exifToolService.addTag(tag.name, to: image.path)
                    } else {
                        try exifToolService.removeTag(tag.name, from: image.path)
                    }
                    writeSucceeded.append(image.id)
                } catch {
                    writeFailed.append(image.url.lastPathComponent)
                }
            }
            // ここから先はMainActor.run側のクロージャに渡すだけの読み取り専用データにする。
            // varのまま`Task.detached`と`MainActor.run`の2つのクロージャに跨って参照/mutateすると
            // Swift 6の厳格な並行性チェックで警告（将来的にはエラー）になるため、`let`に固定してから渡す。
            let succeededIds = writeSucceeded
            let writeFailedNames = writeFailed
            await MainActor.run {
                // コードレビュー指摘の修正：以前は成功/失敗の件数しか出さず、単体版
                // （`toggleTag(tagId:on:ImageRecord)`）と違ってどのファイルがなぜ失敗したか
                // 分からなかった。ファイル名を集約し、失敗があるときは（単体版と同じ重み付けで）
                // トーストではなくモーダルアラートで出す。
                var dbFailedNames: [String] = []
                for imageId in succeededIds {
                    do {
                        if shouldAdd {
                            try self.tagRepository.addTagToImage(imageId: imageId, tagId: tagId)
                        } else {
                            try self.tagRepository.removeTagFromImage(imageId: imageId, tagId: tagId)
                        }
                    } catch {
                        if let name = targets.first(where: { $0.id == imageId })?.url.lastPathComponent {
                            dbFailedNames.append(name)
                        }
                    }
                }
                self.reloadTags()
                self.reloadImages()
                self.inFlightToggles.subtract(keys)
                let allFailedNames = writeFailedNames + dbFailedNames
                let updatedCount = succeededIds.count - dbFailedNames.count
                if allFailedNames.isEmpty {
                    self.showToast("\(updatedCount)件のタグを更新したよ")
                } else {
                    self.presentAlert(
                        message: "一部のタグ付けに失敗した",
                        informative: "\(updatedCount)件成功。失敗: \(FailureSummary.text(names: allFailedNames))"
                    )
                }
            }
        }
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
}
