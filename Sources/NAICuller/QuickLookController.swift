import AppKit
import Combine
// QuickLookUI(Quartz)はSwift concurrencyの注釈を持たないObjective-C API。
// `QLPreviewPanelDataSource`等の適合先メソッドは実際には常にメインスレッドから
// 呼ばれるが、コンパイラはそれを知らないため`@preconcurrency`で監査対象外として扱う。
@preconcurrency import Quartz
import NAICullerCore

/// フォーカス中の画像をQuick Look（Finderでスペースキーを押すのと同じ標準パネル）で
/// リサイズ可能な別ウィンドウとして大きく表示する（実際に使ってみてのフィードバックで追加。
/// それまでは別アプリで開く以外に大きく見る手段が無かった）。
///
/// 自前でプレビュー用ウィンドウを実装せず`QLPreviewPanel`（QuickLookUIの標準API）を使う。
/// リサイズ可能・拡大縮小・複数モニタ対応が最初から揃っており、`appModel.focusedImageId`の
/// 変化を購読してパネルを開いたまま選択を切り替えても表示が追従するようにするだけで済む。
@MainActor
final class QuickLookController: NSObject {
    private weak var appModel: AppModel?
    private var focusedImageCancellable: AnyCancellable?

    init(appModel: AppModel) {
        self.appModel = appModel
        super.init()
        // パネルを開いたまま矢印キーやクリックで選択を変えたときに表示を追従させる。
        focusedImageCancellable = appModel.$focusedImageId.sink { _ in
            guard let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
            panel.reloadData()
        }
    }

    /// スペースキー・ツールバーボタン・右クリックメニューの共通の入口。
    func toggle() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.dataSource = self
            panel.delegate = self
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func currentPreviewURL() -> URL? {
        guard let appModel, let id = appModel.focusedImageId,
              let image = appModel.filteredImages.first(where: { $0.id == id }) else { return nil }
        return image.url
    }
}

// QLPreviewPanelDataSourceはSwift concurrencyの注釈を持たないObjective-Cプロトコルの
// ためisolationが「nonisolated」扱いになる。実際にはQLPreviewPanelが常にメインスレッドから
// 呼び出すAPIなので、`nonisolated`で受けた上で`MainActor.assumeIsolated`でメインアクター
// コンテキストに入り直す（レガシーなAppKitコールバックをSwift concurrencyへ橋渡しする
// 公式に想定された書き方）。
extension QuickLookController: QLPreviewPanelDataSource {
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { currentPreviewURL() == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { currentPreviewURL() as NSURL? }
    }
}

extension QuickLookController: QLPreviewPanelDelegate {}
