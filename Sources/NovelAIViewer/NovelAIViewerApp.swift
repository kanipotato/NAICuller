import SwiftUI

@main
struct NovelAIViewerApp: App {
    @StateObject private var appModel = AppModel()
    @State private var keyCommandHandler: KeyCommandHandler?

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
