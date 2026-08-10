import AppKit
import SwiftUI

/// アプリ終了時の後片付け（常駐exiftoolプロセスの穏当な終了）のためだけのデリゲート。
/// レビュー指摘：終了処理を持たないと、通常のアプリ終了（Cmd+Q等、`NSApplication`が
/// 内部で`exit()`する経路）ではSwiftのdeinitチェーンが保証されず、exiftoolの子プロセスが
/// オーファンとして残り続けることを実機で確認した。
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var appModel: AppModel?

    func applicationWillTerminate(_ notification: Notification) {
        appModel?.shutdown()
    }
}

@main
struct NAICullerApp: App {
    @StateObject private var appModel = AppModel()
    @State private var keyCommandHandler: KeyCommandHandler?
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environmentObject(appModel)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    if keyCommandHandler == nil {
                        let handler = KeyCommandHandler(appModel: appModel)
                        handler.start()
                        keyCommandHandler = handler
                    }
                    appDelegate.appModel = appModel
                }
        }
        .windowResizability(.contentSize)

        // 設定ウィンドウ（メニューから別窓。詳細設計 1章）。SwiftUIの`Settings`シーンは
        // 標準でCmd+,・アプリメニューの「設定…」に自動で紐づく。
        Settings {
            SettingsView()
                .environmentObject(appModel)
                .frame(width: 480, height: 420)
        }
    }
}
