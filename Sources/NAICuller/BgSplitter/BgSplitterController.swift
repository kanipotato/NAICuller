import AppKit
import Foundation
import NAICullerCore

/// bg-splitter（背景透過・シート分割）連携の状態と操作をまとめたコントローラ。
///
/// 元は`AppModel`の中に、設定5項目の`@Published`・検出状態・実行中ジョブの排他集合・
/// 実行メソッド4種・やり直しシートの下ごしらえまで全部同居していた（`AppModel`が
/// 1000行を超えた主因の1つ）。bg-splitterは「無ければメニューごと消える」プラグイン扱いの
/// 機能で、アプリ本体の状態（画像・タグ・絞り込み）と共有する状態が1つも無いため、
/// `AppModel`から最も素直に切り離せる単位としてここへ独立させた。
///
/// トースト表示だけは`AppModel.toastMessage`（`MainWindowView`が観測している唯一の
/// トースト表示口）に集約されているため、クロージャの注入で受ける。アラートは状態を
/// 持たないので`AlertPresenter`を直接呼ぶ。
@MainActor
final class BgSplitterController: ObservableObject {
    // MARK: - 検出状態

    /// `bgsplit.py`と専用venvのpython3が揃っているか。falseの間は右クリックメニューに
    /// 項目自体を出さない（他のNAICullerユーザーの環境では常にfalseになる想定）。
    @Published private(set) var isAvailable = false

    // MARK: - 設定（UserDefaultsに永続化）

    // プラグイン扱いの機能なので、DB(SQLite)ではなくアプリ設定として保存する。
    // 空文字列はそれぞれ「既定値を使う」を意味する。

    /// bg-splitterのフォルダ。空なら`BgSplitterService.locate`の既定パスを見る。
    @Published var customPath: String {
        didSet { UserDefaults.standard.set(customPath, forKey: DefaultsKey.customPath) }
    }
    /// 右クリックメニューから明示指定しなかったときに使うモデルID。
    @Published var defaultModel: String {
        didSet { UserDefaults.standard.set(defaultModel, forKey: DefaultsKey.defaultModel) }
    }
    /// 背景透過の出力先。空なら元画像と同じフォルダ。
    @Published var removeOutputPath: String {
        didSet { UserDefaults.standard.set(removeOutputPath, forKey: DefaultsKey.removeOutputPath) }
    }
    /// シート分割の出力先。空なら元画像と同じ場所に`<元名>_split/`を作る。
    @Published var splitOutputPath: String {
        didSet { UserDefaults.standard.set(splitOutputPath, forKey: DefaultsKey.splitOutputPath) }
    }
    /// 分割マニフェスト(`<元名>_manifest.json`)の保存先。空なら分割出力フォルダと同じ場所
    /// （bgsplit.py側の既定）。処理枚数が増えるとマニフェストが分割結果と同じ数だけ
    /// ライブラリ内に散らばるため、専用フォルダに集約して手動で見に行きたい場合に指定する。
    @Published var manifestPath: String {
        didSet { UserDefaults.standard.set(manifestPath, forKey: DefaultsKey.manifestPath) }
    }

    /// UserDefaultsのキー。`AppModel`時代の名前をそのまま維持している
    /// （リネームすると既存ユーザーの設定が初期値に戻ってしまうため）。
    private enum DefaultsKey {
        static let customPath = "bgSplitterCustomPath"
        static let defaultModel = "bgSplitterDefaultModel"
        static let removeOutputPath = "bgSplitterRemoveOutputPath"
        static let splitOutputPath = "bgSplitterSplitOutputPath"
        static let manifestPath = "bgSplitterManifestPath"
    }

    // MARK: - 分割のやり直し

    /// 「この分割をやり直す」の確認シートに渡す下ごしらえ。マニフェストを読めた時だけ
    /// nil以外になり、シートのスライダーはこの`manifest.overflow`（前回使った値）を初期値にする。
    struct SplitRedoRequest: Identifiable {
        let id = UUID()
        let cellImage: ImageRecord
        let manifest: BgSplitterManifest
    }
    @Published var pendingSplitRedo: SplitRedoRequest?

    // MARK: - 内部状態

    private var service: BgSplitterService?
    /// 背景透過/シート分割が(画像, 種別)単位、再分割が出力フォルダ単位で
    /// 二重起動しないためのガード。
    private var inFlightJobs: Set<String> = []

    /// トースト表示の注入口（`AppModel.showToast`が入る）。
    var showToast: ((String) -> Void)?

    init() {
        let defaults = UserDefaults.standard
        customPath = defaults.string(forKey: DefaultsKey.customPath) ?? ""
        defaultModel = defaults.string(forKey: DefaultsKey.defaultModel) ?? BgSplitterModel.defaultModelId
        removeOutputPath = defaults.string(forKey: DefaultsKey.removeOutputPath) ?? ""
        splitOutputPath = defaults.string(forKey: DefaultsKey.splitOutputPath) ?? ""
        manifestPath = defaults.string(forKey: DefaultsKey.manifestPath) ?? ""
        recheck()
    }

    /// bg-splitterの検出をやり直す（起動時、およびSettings画面でパスを変更/「再チェック」した時に呼ぶ）。
    /// `customPath`が空なら既定パス（`BgSplitterService.locate`参照）を見る。
    func recheck() {
        let customRoot = customPath.isEmpty ? nil : URL(fileURLWithPath: customPath)
        guard let located = BgSplitterService.locate(customRoot: customRoot) else {
            isAvailable = false
            service = nil
            return
        }
        service = BgSplitterService(pythonExecutableURL: located.python, scriptURL: located.script)
        isAvailable = true
    }

    // MARK: - 実行

    /// 選択画像を背景透過する。`model`省略時は設定画面のデフォルトモデルを使う
    /// （右クリックメニューの「モデルを指定」サブメニューから呼ぶ時だけ明示的に渡す）。
    /// 出力先は`removeOutputPath`、未指定なら元画像と同じフォルダに`<元名>_nobg.png`。
    /// DBへの取り込みは行わない（見たければ「再スキャン」してもらう。差分スキャンなので
    /// 新規ファイル分だけ軽く取り込める）。
    ///
    /// ガードキーにモデルを含めないのは、出力パスがモデルに依らず同一で、異なるモデルの
    /// 連続実行が同じ`<元名>_nobg.png`へ並行書き込みして壊れうるため（レビュー指摘の修正）。
    func removeBackground(for images: [ImageRecord], model: String? = nil) {
        let resolvedModel = model ?? defaultModel
        let outputDir = removeOutputPath.isEmpty ? nil : URL(fileURLWithPath: removeOutputPath)
        runJob(kind: "remove", on: images) { service, path in
            try service.removeBackground(imagePath: path, model: resolvedModel, outputDirectory: outputDir)
        }
    }

    /// 選択画像をグリッド分割+背景透過する。`model`/出力先の扱いは`removeBackground`と同様。
    /// マニフェストの保存先は`manifestPath`が空なら分割出力フォルダと同じ場所になる。
    func splitSheet(for images: [ImageRecord], model: String? = nil) {
        let resolvedModel = model ?? defaultModel
        let outputDir = splitOutputPath.isEmpty ? nil : URL(fileURLWithPath: splitOutputPath)
        let manifestDir = manifestDirectoryURL
        runJob(kind: "split", on: images) { service, path in
            try service.splitSheet(imagePath: path, model: resolvedModel, outputDirectory: outputDir, manifestDirectory: manifestDir)
        }
    }

    /// 右クリックされた画像が分割セルらしければマニフェストを読み、確認シートを出す準備をする。
    /// 分割セルでない/マニフェストが読めない場合はメニュー自体を出さない設計なので
    /// （`isAvailable`と同様、`ThumbnailGridView`側で先にチェック済み）、
    /// ここに来て読めなかった場合は「ファイルが移動された」等の想定外ケースとしてアラートを出す。
    func requestSplitRedo(for image: ImageRecord) {
        guard let manifest = BgSplitterService.readManifest(
            forCellImagePath: image.path,
            manifestDirectory: manifestDirectoryURL
        ) else {
            AlertPresenter.warn(
                message: "分割時の情報が見つからない",
                informative: "マニフェスト(_manifest.json)が見つからないか、壊れているみたい。元ファイル名を変更していないか・保存先の設定を確認して、それでもダメなら元シートから改めて「シート分割」してね。"
            )
            return
        }
        pendingSplitRedo = SplitRedoRequest(cellImage: image, manifest: manifest)
    }

    func cancelSplitRedo() {
        pendingSplitRedo = nil
    }

    /// `overflow`を指定してマニフェスト記載の元シートを再分割する。出力先は今見ているセルと
    /// 同じフォルダ（＝前回の分割結果と同じ場所）なので、同名セルは上書きされる。
    ///
    /// ガードキーを対象セルのIDではなく出力フォルダのパスにしているのは、同じ元シートから
    /// 切り出された兄弟セル（r0_c0とr0_c1など）のどちらから起動しても同じ出力先・同じ
    /// マニフェストへ書き込むため、フォルダ単位で排他する必要があるから（レビュー指摘の修正）。
    func confirmSplitRedo(overflow: Double) {
        guard let request = pendingSplitRedo else { return }
        pendingSplitRedo = nil
        guard let service else {
            presentServiceMissingAlert()
            return
        }
        let outputDir = URL(fileURLWithPath: request.cellImage.path).deletingLastPathComponent()
        let manifestDir = manifestDirectoryURL
        let sourcePath = request.manifest.source
        let model = request.manifest.model

        let jobKey = "split-redo-\(outputDir.path)"
        guard inFlightJobs.insert(jobKey).inserted else {
            AlertPresenter.warn(message: "すでに再分割中みたい", informative: "完了を待ってからもう一度試してね。")
            return
        }
        showToast?("再分割中…")

        Task.detached(priority: .userInitiated) {
            do {
                _ = try service.splitSheet(
                    imagePath: sourcePath, model: model, outputDirectory: outputDir,
                    overflow: overflow, manifestDirectory: manifestDir
                )
                await MainActor.run { [weak self] in
                    self?.inFlightJobs.remove(jobKey)
                    self?.showToast?("再分割が完了しました")
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.inFlightJobs.remove(jobKey)
                    AlertPresenter.warn(message: "再分割に失敗した", informative: "\(error)")
                }
            }
        }
    }

    // MARK: - 内部ヘルパー

    private var manifestDirectoryURL: URL? {
        manifestPath.isEmpty ? nil : URL(fileURLWithPath: manifestPath)
    }

    private func presentServiceMissingAlert() {
        AlertPresenter.warn(
            message: "bg-splitterが見つからない",
            informative: "設定画面の「背景透過・シート分割」タブでパスを確認してください"
        )
    }

    /// 複数画像への一括実行の共通処理（進捗トースト・二重起動ガード・結果集計）。
    private func runJob(
        kind: String,
        on images: [ImageRecord],
        _ operation: @escaping @Sendable (BgSplitterService, String) throws -> String
    ) {
        guard !images.isEmpty else { return }
        guard let service else {
            presentServiceMissingAlert()
            return
        }
        // 選択の1件でも実行中だとバッチ全体が無反応で捨てられていた不具合の修正として、
        // 実行中でないものだけに絞って処理を続行する（レビュー指摘の修正）。
        let targets = images.filter { !inFlightJobs.contains("\($0.id)-\(kind)") }
        guard !targets.isEmpty else {
            showToast?("すでに処理中だよ")
            return
        }
        let keys = targets.map { "\($0.id)-\(kind)" }
        inFlightJobs.formUnion(keys)

        showToast?(targets.count > 1 ? "\(targets.count)件を処理中…" : "処理中…")

        Task.detached(priority: .userInitiated) {
            var successCount = 0
            var failedNames: [String] = []
            for image in targets {
                do {
                    _ = try operation(service, image.path)
                    successCount += 1
                } catch {
                    failedNames.append("\(image.url.lastPathComponent): \(error)")
                }
            }
            let finalSuccessCount = successCount
            let finalFailedNames = failedNames
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.inFlightJobs.subtract(keys)
                if finalFailedNames.isEmpty {
                    self.showToast?("\(finalSuccessCount)件の処理が完了しました")
                } else if finalSuccessCount == 0 {
                    AlertPresenter.warn(
                        message: "bg-splitterの処理に失敗した",
                        informative: finalFailedNames.joined(separator: "\n")
                    )
                } else {
                    AlertPresenter.warn(
                        message: "\(finalSuccessCount)件完了、\(finalFailedNames.count)件失敗",
                        informative: finalFailedNames.joined(separator: "\n")
                    )
                }
            }
        }
    }
}
