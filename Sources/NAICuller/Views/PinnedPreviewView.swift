import SwiftUI
import AppKit
import NAICullerCore

/// 「この画像を固定表示」用の独立ウィンドウの中身。実際に使ってみてのフィードバックで追加：
/// 既存のQuick Look（`QuickLookController`）は選択に追従する1枚しか出せないため、
/// 比較用にもう1枚を選択に連動させず固定表示しておきたいという要望に応える。
///
/// `QLPreviewPanel`はアプリ全体で1インスタンスしか存在できないシングルトンAPIのため、
/// 「追従する1枚」と「固定の1枚」を両立するにはQuick Lookとは別の表示手段が要る。
/// SwiftUIの値付き`WindowGroup(for:)` + `openWindow(value:)`を使うと、画像ごとに
/// 独立したウィンドウの生成と、同じ画像を指定したときの既存ウィンドウへのフォーカス
/// （新規重複作成ではなく前面化）をOS標準の仕組みに任せられるため、自前でNSWindowの
/// ライフサイクル管理をする必要が無い。
///
/// 意図的に`appModel.filteredImages`ではなく`appModel.images`（絞り込み前の全件）から
/// 画像を探す：固定表示は「今の絞り込み条件」ではなく「あの1枚」を指すものなので、
/// 開いた後にフィルタやソートを変えても表示対象は変わらないのが正しい挙動。
struct PinnedPreviewView: View {
    @EnvironmentObject private var appModel: AppModel
    let imageId: Int64?

    /// コードレビュー指摘の修正：以前は`appModel.images.first(where:)`を計算プロパティとして
    /// bodyから呼んでいた。`@EnvironmentObject`はAppModelのあらゆる`@Published`変化で
    /// bodyを再評価させるため、矢印キーで選択を動かすたび（focusedImageId/selectedImageIdsの
    /// 更新ごと）に開いている固定表示ウィンドウの枚数だけ全画像2万件の線形探索が走っていた。
    /// この機能は「複数窓を開いたまま作業する」のが主旨なので実害が出やすい。
    /// 表示対象はウィンドウの生存期間中ずっと不変なので、一度だけ解決して保持する。
    @State private var resolvedImage: ImageRecord?

    var body: some View {
        Group {
            if let resolvedImage {
                PinnedPreviewImageLoader(image: resolvedImage)
            } else {
                Text("画像が見つからないよ（削除された可能性があるよ）")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 300, minHeight: 200)
            }
        }
        .navigationTitle(resolvedImage.map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? "固定表示")
        .task(id: imageId) {
            guard let imageId else {
                resolvedImage = nil
                return
            }
            resolvedImage = appModel.images.first(where: { $0.id == imageId })
        }
    }
}

/// 画像データの読み込みだけを担当する内側のView。`.task(id:)`を画像IDに紐付けることで、
/// このウィンドウが表示する画像が変わることは無い（固定表示なので）前提を型でも示す。
private struct PinnedPreviewImageLoader: View {
    let image: ImageRecord
    @State private var previewImage: NSImage?

    var body: some View {
        Group {
            if let previewImage {
                Image(nsImage: previewImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView()
            }
        }
        .frame(idealWidth: 560, idealHeight: 560)
        .frame(minWidth: 240, minHeight: 240)
        .task(id: image.id) {
            let path = image.path
            // DetailPanelViewのプレビュー読み込みと同じ理由：NSImageはmacOS14未満で
            // Sendable未対応のため、バックグラウンドではData読み込みまでに留め、
            // NSImageの生成はメインアクター側（await復帰後）で行う。
            let data = await Task.detached(priority: .userInitiated) {
                try? Data(contentsOf: URL(fileURLWithPath: path))
            }.value
            previewImage = data.flatMap { NSImage(data: $0) }
        }
    }
}
