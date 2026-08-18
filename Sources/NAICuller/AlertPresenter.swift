import AppKit

/// モーダルな警告ダイアログの表示口。
///
/// 元は`AppModel`に`presentAlert` / `presentFatalAlert`としてほぼ同一の実装が2つ並んでいた。
/// bg-splitter連携を`BgSplitterController`へ切り出すにあたり、同じものを3つ目として
/// 複製したくないため、`alertStyle`だけが違う共通処理としてここへまとめる。
///
/// 状態を持たずAppKitを直接叩くだけなので`ObservableObject`にはしない。
enum AlertPresenter {
    /// 操作は中断するがアプリは続行できる警告（詳細設計5章「クラッシュさせない」方針）。
    @MainActor
    static func warn(message: String, informative: String? = nil) {
        run(style: .warning, message: message, informative: informative)
    }

    /// 続行不能に近い致命的エラー（DBを開けない等）。
    @MainActor
    static func fatal(message: String, informative: String? = nil) {
        run(style: .critical, message: message, informative: informative)
    }

    @MainActor
    private static func run(style: NSAlert.Style, message: String, informative: String?) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = message
        if let informative { alert.informativeText = informative }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
