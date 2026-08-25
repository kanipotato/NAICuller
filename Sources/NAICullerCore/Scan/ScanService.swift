import Foundation

/// ルートが存在しない・アクセス不可だった場合の警告（詳細設計 5章）。
public struct ScanWarning: Equatable, Sendable {
    public var rootPath: String
    public var reason: String
}

/// スキャン結果のサマリ。
public struct ScanResult: Equatable, Sendable {
    public var newImageCount: Int = 0
    public var updatedImageCount: Int = 0
    public var unchangedImageCount: Int = 0
    /// 強制再スキャン（`forceFullRescan`）で、ファイル内容自体(mtime/file_size)は変わって
    /// いないのにメタデータだけ再読み込みした件数。ExifTool再読込・DB更新は行うが、
    /// pixelが変わっていないためサムネイルキャッシュは無効化しない（`changedImageIds`には含めない）。
    public var forcedRereadCount: Int = 0
    public var warnings: [ScanWarning] = []
    /// ファイルシステム上に実体が無くなったレコード（削除するかはUI側でユーザーに確認する。詳細設計 5章）。
    public var orphanImages: [(id: Int64, path: String)] = []
    /// 新規または（内容が実際に）更新された画像のID。サムネイルキャッシュの無効化対象として呼び出し側に渡す。
    public var changedImageIds: [Int64] = []

    public init() {}

    public static func == (lhs: ScanResult, rhs: ScanResult) -> Bool {
        lhs.newImageCount == rhs.newImageCount
            && lhs.updatedImageCount == rhs.updatedImageCount
            && lhs.unchangedImageCount == rhs.unchangedImageCount
            && lhs.forcedRereadCount == rhs.forcedRereadCount
            && lhs.warnings == rhs.warnings
            && lhs.orphanImages.map(\.id) == rhs.orphanImages.map(\.id)
            && lhs.changedImageIds == rhs.changedImageIds
    }
}

/// ルート配下を再帰的に列挙し、DBとの差分に応じてExifTool読み込み・DB更新を行う（詳細設計 4-1章）。
///
/// 2回目以降のスキャンでmtime/file_sizeが両方一致するファイルはExifToolを呼ばずスキップする
/// （受け入れ基準：「2回目以降のスキャンで変更のないファイルの再読み込みが発生しない」）。
public final class ScanService {
    private let imageRepository: ImageRepository
    private let tagRepository: TagRepository
    private let exifTool: ExifMetadataReading
    private let fileManager: FileManager

    public init(imageRepository: ImageRepository, tagRepository: TagRepository, exifTool: ExifMetadataReading, fileManager: FileManager = .default) {
        self.imageRepository = imageRepository
        self.tagRepository = tagRepository
        self.exifTool = exifTool
        self.fileManager = fileManager
    }

    /// 指定ルート群をスキャンする。呼び出し側（UI層）はメインスレッドをブロックしないよう
    /// バックグラウンドキューから呼ぶこと（本メソッド自体は同期実行）。
    ///
    /// - Parameter forceFullRescan: trueの場合、mtime/file_sizeが一致していても全ファイルを
    ///   ExifToolで再読み込みする（設定画面の「強制再スキャン」用。アプリの機能追加でメタデータの
    ///   読み取り項目が増えた際、v1時代からの既存画像には差分スキャンでは反映されないための
    ///   救済手段。実際に使ってみてのフィードバックで発覚：source_platform/生成パラメータ対応を
    ///   追加した際、通常の再スキャンでは既存画像に一切反映されなかった）。
    public func scan(roots: [Root], forceFullRescan: Bool = false) throws -> ScanResult {
        var result = ScanResult()
        for root in roots {
            try scanOneRoot(root, forceFullRescan: forceFullRescan, into: &result)
        }
        return result
    }

    private func scanOneRoot(_ root: Root, forceFullRescan: Bool, into result: inout ScanResult) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            // ルートが存在しない/アクセス不可：このrootをスキップして次のrootへ（他ルートは継続）。
            // 実体が一時的に見えないだけの可能性がある（外付けドライブ未マウント等）ため、
            // 既存レコードは孤児扱いにしない。
            result.warnings.append(ScanWarning(rootPath: root.path, reason: "ディレクトリが存在しないか、アクセスできない"))
            return
        }

        let existingByPath = try imageRepository.fetchAllPaths(rootId: root.id)
            .reduce(into: [String: Int64]()) { dict, pair in dict[pair.value] = pair.key }
        var existingRecordsById: [Int64: ImageRecord] = [:]
        for record in try imageRepository.fetchImages(rootId: root.id) {
            existingRecordsById[record.id] = record
        }

        var seenIds = Set<Int64>()

        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: root.path),
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            result.warnings.append(ScanWarning(rootPath: root.path, reason: "ディレクトリの列挙に失敗した"))
            return
        }

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension.lowercased() == "png" else { continue }
            let resourceValues = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
            guard resourceValues?.isRegularFileKeyIfAvailable != false else { continue }
            guard let mtimeDate = resourceValues?.contentModificationDate,
                  let fileSize = resourceValues?.fileSize else {
                // ファイルが列挙後スキャン中に外部から消えた等。スキップして次へ（詳細設計 5章）。
                continue
            }
            let path = fileURL.path
            let mtime = mtimeDate.timeIntervalSince1970

            if let existingId = existingByPath[path], let existing = existingRecordsById[existingId] {
                seenIds.insert(existingId)
                let contentUnchanged = existing.mtime == mtime && existing.fileSize == Int64(fileSize)
                if contentUnchanged, !forceFullRescan {
                    result.unchangedImageCount += 1
                    continue
                }
                // 変更あり、または強制再スキャン：ExifTool再読込、prompt_cache上書き
                // （サムネキャッシュの無効化は呼び出し側がchangedImageIdsを見て行う。
                // 強制再スキャンでcontentUnchangedな場合はpixelが変わっていないので
                // changedImageIdsに入れず、無駄なサムネイル再生成をさせない）。
                let metadata = try? exifTool.readMetadata(path: path)
                try imageRepository.updateImage(
                    id: existingId,
                    mtime: mtime,
                    fileSize: Int64(fileSize),
                    width: metadata?.width,
                    height: metadata?.height,
                    promptCache: metadata?.promptDescription,
                    sourcePlatform: metadata.map(ImageSourcePlatform.detect) ?? .unknown,
                    comfyGenerationInfoJSON: metadata?.comfyPromptJSON,
                    naiGenerationInfoJSON: metadata?.naiCommentJSON
                )
                if let metadata {
                    try syncTags(imageId: existingId, tagNames: metadata.tagNames)
                }
                if contentUnchanged {
                    result.forcedRereadCount += 1
                } else {
                    result.updatedImageCount += 1
                    result.changedImageIds.append(existingId)
                }
            } else {
                // 新規：ExifToolで読んでimages/tags初期化。
                let metadata = try? exifTool.readMetadata(path: path)
                let newId = try imageRepository.insertImage(
                    rootId: root.id,
                    path: path,
                    mtime: mtime,
                    fileSize: Int64(fileSize),
                    width: metadata?.width,
                    height: metadata?.height,
                    promptCache: metadata?.promptDescription,
                    sourcePlatform: metadata.map(ImageSourcePlatform.detect) ?? .unknown,
                    comfyGenerationInfoJSON: metadata?.comfyPromptJSON,
                    naiGenerationInfoJSON: metadata?.naiCommentJSON
                )
                seenIds.insert(newId)
                if let metadata {
                    try syncTags(imageId: newId, tagNames: metadata.tagNames)
                }
                result.newImageCount += 1
                result.changedImageIds.append(newId)
            }
        }

        // 孤児レコード：DB上にあるがファイルシステム上で見つからなかったもの。
        for (id, record) in existingRecordsById where !seenIds.contains(id) {
            result.orphanImages.append((id: id, path: record.path))
        }
    }

    /// 画像ファイル側のXMP:Subject（正データ）からimage_tagsを復元・同期する。
    /// タグ名が既存タグに（大文字小文字区別なく）一致すればそれに紐付け、無ければ
    /// ユーザー定義タグとして新規作成する。ファイル側に無くなったタグはimage_tagsからも外す。
    private func syncTags(imageId: Int64, tagNames: [String]) throws {
        var targetTagIds = Set<Int64>()
        for rawName in tagNames {
            guard let name = TagNameValidator.normalize(rawName) else { continue }
            if let existing = try tagRepository.fetchByNameCaseInsensitive(name) {
                targetTagIds.insert(existing.id)
            } else {
                let newId = try tagRepository.insertUserTag(name: name)
                targetTagIds.insert(newId)
            }
        }
        let currentTagIds = try tagRepository.tagIds(forImage: imageId)
        for tagId in targetTagIds.subtracting(currentTagIds) {
            try tagRepository.addTagToImage(imageId: imageId, tagId: tagId)
        }
        for tagId in currentTagIds.subtracting(targetTagIds) {
            try tagRepository.removeTagFromImage(imageId: imageId, tagId: tagId)
        }
    }
}

private extension URLResourceValues {
    /// isRegularFileKeyは環境によって取得できないことがあるため、失敗時はnilではなくtrue扱いにして
    /// フィルタで弾かないようにする（安全側：判定不能なら通常ファイルとみなす）。
    var isRegularFileKeyIfAvailable: Bool { isRegularFile ?? true }
}
