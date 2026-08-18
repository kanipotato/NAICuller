import Foundation
import AppKit
import NAICullerCore

/// アプリ全体の状態と、Core層サービスへの窓口をまとめる中心的なObservableObject。
/// SwiftUIビュー群はこれを`@EnvironmentObject`（または直接渡し）で参照する。
///
/// Bundle IDは既存アプリ群（AudioSwitcher/DeskDogs）と同じ`io.github.kanipotato.*`の
/// 命名規則に揃えて`io.github.kanipotato.naiculler`とした
/// （詳細設計は`com.kanipotato.NAICuller`を例示していたが「等、一貫性のある命名で良い」
/// との指示のため、既存アプリの流儀を優先した）。
@MainActor
final class AppModel: ObservableObject {
    static let bundleIdentifier = "io.github.kanipotato.naiculler"

    // MARK: - Core services

    private(set) var db: DatabaseService!
    private(set) var imageRepository: ImageRepository!
    private(set) var tagRepository: TagRepository!
    private(set) var thumbnailService: ThumbnailService!
    private(set) var exportService = ExportService()
    private(set) var quickLookController: QuickLookController!
    private var exifToolService: ExifToolService?
    private var scanService: ScanService?

    /// bg-splitter（背景透過・シート分割）連携。アプリ本体の状態と共有するものが無い
    /// プラグイン扱いの機能なので、状態も操作も`BgSplitterController`側に閉じている。
    /// SwiftUIビューは`@EnvironmentObject`でこれを直接観測する（`NAICullerApp`が注入）。
    /// AppKit側（`ThumbnailGridView`の右クリックメニュー）からは`appModel.bgSplitter`で辿る。
    let bgSplitter = BgSplitterController()

    /// 固定表示ウィンドウを開くためのブリッジ。SwiftUIの`openWindow`環境アクションは
    /// View（今回は`NAICullerApp`自身）でしか取得できないため、AppKit側の右クリック
    /// メニューハンドラ（`ThumbnailGridView.Coordinator`）から呼べるようクロージャとして
    /// 注入してもらう（ExifTool終了処理を`AppDelegate`経由でAppModelに注入しているのと
    /// 同じ、View外からSwiftUIのシーンAPIを呼ぶための橋渡しパターン）。
    var openPinnedPreviewWindow: ((Int64) -> Void)?

    /// 右クリックメニュー「この画像を固定表示」の入口。選択に追従しない比較用ウィンドウを
    /// 画像ごとに開く（実際に使ってみてのフィードバックで追加：Quick Lookは選択に追従する
    /// 1枚しか出せないため、比較したい2枚を並べて置いておく手段が無かった）。
    func showPinnedPreview(for image: ImageRecord) {
        openPinnedPreviewWindow?(image.id)
    }

    // MARK: - Published state

    @Published private(set) var roots: [Root] = []
    @Published private(set) var rootWarnings: [String: String] = [:] // rootPath -> reason
    @Published private(set) var tags: [Tag] = []
    @Published private(set) var tagCounts: [Int64: Int] = [:]
    @Published private(set) var images: [ImageRecord] = []
    @Published private(set) var imageTagIds: [Int64: Set<Int64>] = [:] // imageId -> tagIds（グリッド/フィルタ用キャッシュ）
    /// ルート・タグ・プロンプト検索・並び替えを適用した結果。グリッド・エクスポート対象は
    /// すべてこれを見る。フィルタ条件が変わるたびに`refreshFilteredImages()`で再計算する
    /// キャッシュ（1万枚超を毎フレーム計算し直すのを避けるため。以前は`var`の計算プロパティ
    /// だったが、並び替え追加でファイル名の`localizedStandardCompare`のような重い比較が
    /// 増えたのを機に、明示的な再計算タイミングを持つ形に変更した）。
    @Published private(set) var filteredImages: [ImageRecord] = []

    @Published var selectedTagIds: Set<Int64> = [] {
        didSet {
            // showUntaggedOnlyとの排他はこれまで片方向（showUntaggedOnly→selectedTagIds解除）
            // だけだった。サイドバーのタグクリックはselectedTagIdsを直接書き換えるため、
            // 「未タグのみ」表示中にタグをクリックすると絞り込みの実体（showUntaggedOnly）と
            // 見た目（選択済み表示のタグ・チップ表示）が食い違うコードレビュー指摘があった。
            // 双方向にすることで、どちらから変更してもお互いを正しく解除し合うようにする。
            // コードレビュー指摘の修正：「削除対象タグで絞り込む」と「削除対象を除外」も
            // 必ず0件になる組み合わせなので、`showUntaggedOnly`と同じく相手側を自動解除する。
            if hideDeletionMarked, let markId = deletionMarkTagId(), selectedTagIds.contains(markId) {
                hideDeletionMarked = false // didSetの中でrefreshFilteredImages()が呼ばれる
            } else if !selectedTagIds.isEmpty, showUntaggedOnly {
                showUntaggedOnly = false // didSetの中でrefreshFilteredImages()が呼ばれる
            } else {
                refreshFilteredImages()
            }
        }
    }
    /// サイドバーのルートチェックボックスで有効化されているルート（未チェックのルート配下の画像は
    /// グリッドから一時的に除外する。DBからは削除しない表示フィルタ）。
    @Published var enabledRootIds: Set<Int64> = [] {
        didSet { refreshFilteredImages() }
    }
    /// プロンプト本文に対する部分一致検索（大文字小文字は区別しない）。空文字なら絞り込まない。
    /// タグを付ける前の画像を「プロンプトの内容」で見つけるための入り口として追加した。
    ///
    /// コードレビュー指摘の修正：以前はキー入力のたびに同期で`refreshFilteredImages()`を
    /// 呼んでおり、1万枚超のライブラリでは1文字打つごとに全件フィルタ＋再ソートが走って
    /// 入力がもたついていた。200ms のデバウンスを挟み、入力が止まってから1回だけ実行する。
    @Published var promptSearchText: String = "" {
        didSet {
            searchDebounceTask?.cancel()
            searchDebounceTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.refreshFilteredImages() }
            }
        }
    }
    @Published var sortOrder: ImageSortOrder = .dateNewest {
        didSet { refreshFilteredImages() }
    }
    /// プロンプト候補絞り込み（AND条件：選択した全語句を含む画像のみ）。
    /// 実際に使ってみてのフィードバックで追加：ルート内にどんなプロンプトがあるか
    /// 事前に把握していないと`promptSearchText`に何を打てばいいか分からないため、
    /// 候補を分析して選ぶ入り口を用意した。
    @Published var selectedPromptTerms: Set<String> = [] {
        didSet { refreshFilteredImages() }
    }
    /// `analyzePromptCandidates()`の結果（頻度順）。ポップオーバーを開くたびに再計算する。
    @Published private(set) var promptCandidates: [PromptCandidate] = []
    @Published private(set) var isAnalyzingPromptCandidates = false
    /// タグが1つも付いていない画像だけを表示する（実際に使ってみてのフィードバックで追加。
    /// タグ付け済みのものはタグ絞り込みで見つけられるが、その裏返し＝「まだ手を付けていない
    /// もの」を残すためのフィルタが無かった）。ONにした瞬間、タグ絞り込みと同時に使うと
    /// 意味が食い違う（両方ONだと必ず0件になる）ため、選択中のタグ絞り込みは自動で解除する。
    @Published var showUntaggedOnly: Bool = false {
        didSet {
            if showUntaggedOnly, !selectedTagIds.isEmpty {
                selectedTagIds.removeAll() // didSetの中でrefreshFilteredImages()が呼ばれる
            } else {
                refreshFilteredImages()
            }
        }
    }
    /// 「削除対象」タグが付いた画像を表示から除外する（実際に使ってみてのフィードバックで追加。
    /// ゴミ箱移動の対象として一旦マークした画像が、その後もタグ付け作業中ずっとグリッドに
    /// 残り続けて邪魔になるため）。タグ絞り込み・未タグのみ・プロンプト検索/候補とは
    /// 独立して重ねがけできる単純なON/OFFのふるい落とし。
    ///
    /// コードレビュー指摘の修正：唯一「削除対象タグでの絞り込み」とだけは必ず0件になる
    /// 組み合わせなので、`showUntaggedOnly`と`selectedTagIds`が既にそうしているのと同じ流儀で
    /// 相手側を自動解除する（矛盾した条件で空グリッドを見せて理由が分からない状態にしない）。
    @Published var hideDeletionMarked: Bool = false {
        didSet {
            if hideDeletionMarked, let markId = deletionMarkTagId(), selectedTagIds.contains(markId) {
                selectedTagIds.remove(markId) // didSetの中でrefreshFilteredImages()が呼ばれる
            } else {
                refreshFilteredImages()
            }
        }
    }
    @Published var selectedImageIds: Set<Int64> = []
    @Published var focusedImageId: Int64?
    @Published var thumbnailSize: ThumbnailSize = .medium

    @Published private(set) var exifToolAvailable = false

    @Published private(set) var isScanning = false
    @Published var toastMessage: String?
    @Published var pendingOrphans: [(id: Int64, path: String)] = []
    @Published var showOrphanConfirmation = false

    /// 「削除対象」タグ付き画像のゴミ箱移動範囲。確認ダイアログを出す前の下ごしらえとして
    /// nil以外を保持する（実際の移動はconfirmDeleteMarkedImages()を呼ぶまで実行しない）。
    enum DeletionScope {
        case selected
        case all
    }
    @Published var pendingDeletionScope: DeletionScope?
    @Published private(set) var pendingDeletionCount: Int = 0

    private var toastDismissTask: Task<Void, Never>?
    private var searchDebounceTask: Task<Void, Never>?
    /// プロンプト候補分析の進行中タスク。コードレビュー指摘の修正：多重起動のガードが無く、
    /// 先に開始した分析が後から終わると新しい結果を古い結果で上書きしうる（かつ先に終わった
    /// 方が`isAnalyzingPromptCandidates`をfalseにするのでスピナーが早く消える）ため、
    /// 新しい分析を始める前に前のものをキャンセルする。
    private var promptAnalysisTask: Task<Void, Never>?
    /// 画像IDごとのプロンプト語句集合のキャッシュ。コードレビュー指摘の修正：以前は
    /// `refreshFilteredImages()`のフィルタ内で毎回`PromptCandidateAnalyzer.terms(in:)`を
    /// 呼んでおり、プロンプト候補で絞り込み中はタグ付けキーを1打鍵するたびに
    /// （toggleTag→reloadImages→refreshFilteredImages の経路で）全画像分のプロンプト文字列を
    /// 分割・小文字化・Set生成し直していた。2万枚規模では打鍵ごとに体感できる停止になる。
    /// プロンプト本文は再スキャンでしか変わらないので、画像IDをキーに使い回す。
    private var promptTermsCache: [Int64: Set<String>] = [:]
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
        quickLookController = QuickLookController(appModel: self)
        // トーストの表示口はAppModel側（MainWindowViewが観測している`toastMessage`）に
        // 集約されているため、切り出したコントローラへは呼び出し口だけ渡す。
        bgSplitter.showToast = { [weak self] message in self?.showToast(message) }
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
        // コードレビュー指摘の修正：以前は画像1件ごとに`tagIds(forImage:)`を呼んでおり、
        // 1万枚超の実ライブラリでは`reloadImages()`が呼ばれるたびに1万回超のSQLite
        // 問い合わせが発生していた（一括タグ付け・ゴミ箱移動の追加でreloadImages()の
        // 呼び出し頻度自体も増えたため、より顕在化しやすくなっていた）。1回のSELECTで
        // 全画像分をまとめて取得する`allImageTagIds()`に置き換える。
        let allTagIds = (try? tagRepository.allImageTagIds()) ?? [:]
        imageTagIds = images.reduce(into: [Int64: Set<Int64>]()) { mapping, image in
            mapping[image.id] = allTagIds[image.id] ?? []
        }
        refreshFilteredImages()
    }

    /// サイドバーのルートチェックボックス・タグ絞り込み（AND条件：選択した全タグを持つ画像のみ）・
    /// プロンプト検索・プロンプト候補絞り込み・削除対象の除外を適用し、`sortOrder`で並び替えた
    /// 結果を`filteredImages`に反映する。
    private func refreshFilteredImages() {
        let criteria = ImageFilterCriteria(
            enabledRootIds: enabledRootIds,
            selectedTagIds: selectedTagIds,
            showUntaggedOnly: showUntaggedOnly,
            hiddenDeletionMarkTagId: hideDeletionMarked ? deletionMarkTagId() : nil,
            promptSearchText: promptSearchText,
            selectedPromptTerms: selectedPromptTerms
        )
        let narrowed = ImageFilter.apply(
            to: images,
            imageTagIds: imageTagIds,
            criteria: criteria,
            promptTerms: { [unowned self] in self.promptTerms(for: $0) }
        )
        filteredImages = sortOrder.sorted(narrowed)

        // コードレビュー指摘の修正：フィルタで画面から消えた画像のIDが`selectedImageIds`に
        // 残り続けていた（グリッド側の見た目の選択解除はNSCollectionView側でしか反映されず、
        // appModel.selectedImageIds自体は素通りだった）。「ゴミ箱移動」機能は
        // `selectedImageIds`をそのまま対象にするため、見えなくなった画像が紛れ込んだまま
        // 削除されてしまう実害があった。ここで常に見えている画像のIDだけに絞り込む。
        let visibleIds = Set(filteredImages.map(\.id))
        selectedImageIds.formIntersection(visibleIds)
        if let focusedImageId, !visibleIds.contains(focusedImageId) {
            self.focusedImageId = nil
        }
    }

    // MARK: - プロンプト候補絞り込み

    /// 画像1件分のプロンプト語句集合を返す（`promptTermsCache`経由で使い回す）。
    private func promptTerms(for image: ImageRecord) -> Set<String> {
        if let cached = promptTermsCache[image.id] { return cached }
        let terms = PromptCandidateAnalyzer.terms(in: image.promptCache ?? "")
        promptTermsCache[image.id] = terms
        return terms
    }

    /// 「有効なルート」内の画像プロンプトを分析し、`promptCandidates`を更新する
    /// （プロンプト候補絞り込みポップオーバーを開いたとき・再分析ボタンで呼ぶ）。
    /// タグ絞り込みや既存のプロンプト検索は意図的に無視する：あくまで「今見えているルート内に
    /// どんなプロンプトがあるか」の全体像を示す入り口なので、他の絞り込み条件で候補自体が
    /// 先細りしていく（後から使いたかった語句が候補から消える）のを避けるため。
    func analyzePromptCandidates() {
        // コードレビュー指摘の修正：前回の分析が走っていれば捨てる（結果の追い越しを防ぐ）。
        promptAnalysisTask?.cancel()
        isAnalyzingPromptCandidates = true
        let prompts = images
            .filter { enabledRootIds.contains($0.rootId) }
            .compactMap(\.promptCache)
        promptAnalysisTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                PromptCandidateAnalyzer.analyze(prompts: prompts)
            }.value
            // キャンセル済み（＝より新しい分析が始まっている）なら結果もスピナーも触らない。
            guard !Task.isCancelled, let self else { return }
            self.promptCandidates = result
            self.isAnalyzingPromptCandidates = false
        }
    }

    // MARK: - ルート管理

    /// フォルダ選択パネルを出してルートを追加し、成功したら続けてスキャンする。
    /// メインウィンドウのツールバーと設定画面の両方から呼ばれる。
    ///
    /// 元は`MainWindowView`と`RootsSettingsTab`にほぼ同一の`chooseRoot()`が置かれていた
    /// （コードレビュー指摘）。過去に「設定画面から追加したときだけ自動スキャンが抜けていて、
    /// ルートを追加しても画像が0件のまま何も起きていないように見える」不具合があった箇所で、
    /// 手順が2箇所に散っていると同じ取りこぼしが再発しうるためここへ集約する。
    ///
    /// - Returns: 追加に失敗した場合の表示用メッセージ。成功時・キャンセル時はnil
    ///   （呼び出し側はこれをそのままエラー表示用の状態へ代入すればよい）。
    func chooseAndAddRoot() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "追加"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        if let failure = addRoot(path: url.path) {
            return failure.message
        }
        rescan()
        return nil
    }

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
                // プロンプト本文が変わりうるのは再スキャンのときだけなので、
                // 語句キャッシュの破棄もここだけでよい（毎回のreloadImagesでは捨てない。
                // 捨ててしまうとタグ付け1打鍵ごとに再構築が走り、キャッシュの意味が無くなる）。
                self.promptTermsCache.removeAll()
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

    // MARK: - 削除対象タグの一括削除（実際に使ってみてのフィードバックで追加）
    //
    // ドラフト段階の設計方針「アプリはファイルシステムに破壊的操作をしない」から意図的に外れる
    // 唯一の例外。ドラフトの「懸念・未解決」でも「ゴミ箱移動(NSWorkspace.recycle)は初版スコープ外。
    // 将来必要なら追加検討」と明記していた、その"将来"が実際に来た形。事故を避けるため、
    // 完全削除ではなく常にゴミ箱移動（復元可能）にし、対象は常に「削除対象タグが付いている画像」
    // だけに厳密に絞る（選択に紛れ込んだ未タグの画像は対象外として黙って除外する）。

    /// 選択中の画像のうち「削除対象」タグが付いているものだけを数え、確認ダイアログの表示を要求する。
    /// 実際の移動はconfirmDeleteMarkedImages()を呼ぶまで実行しない。
    func requestDeleteSelectedMarkedImages() {
        let targets = selectedMarkedImages()
        guard !targets.isEmpty else {
            showToast("選択中に「削除対象」タグの画像が無いよ")
            return
        }
        pendingDeletionCount = targets.count
        pendingDeletionScope = .selected
    }

    /// ライブラリ全体で「削除対象」タグが付いている画像（選択状態やフィルタとは無関係）を数え、
    /// 確認ダイアログの表示を要求する。
    func requestDeleteAllMarkedImages() {
        let targets = allMarkedImages()
        guard !targets.isEmpty else {
            showToast("「削除対象」タグの画像が無いよ")
            return
        }
        pendingDeletionCount = targets.count
        pendingDeletionScope = .all
    }

    func confirmDeleteMarkedImages() {
        guard let scope = pendingDeletionScope else { return }
        let targets = scope == .selected ? selectedMarkedImages() : allMarkedImages()
        pendingDeletionScope = nil
        performTrashDeletion(targets)
    }

    func cancelDeleteMarkedImages() {
        pendingDeletionScope = nil
    }

    private func deletionMarkTagId() -> Int64? {
        tags.first(where: { $0.name == Tag.SystemTagName.deletionMark })?.id
    }

    private func selectedMarkedImages() -> [ImageRecord] {
        guard let tagId = deletionMarkTagId() else { return [] }
        let markedIds = (try? tagRepository.imageIds(taggedWith: tagId)) ?? []
        return images.filter { selectedImageIds.contains($0.id) && markedIds.contains($0.id) }
    }

    private func allMarkedImages() -> [ImageRecord] {
        guard let tagId = deletionMarkTagId() else { return [] }
        let markedIds = (try? tagRepository.imageIds(taggedWith: tagId)) ?? []
        return images.filter { markedIds.contains($0.id) }
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

    // MARK: - パスコピー

    func copyPath(of image: ImageRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(image.path, forType: .string)
        showToast("パスをコピーしました")
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
        AlertPresenter.warn(message: message, informative: informative)
    }

    private func presentFatalAlert(message: String, informative: String?) {
        AlertPresenter.fatal(message: message, informative: informative)
    }
}
