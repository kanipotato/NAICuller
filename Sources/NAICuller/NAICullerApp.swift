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
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environmentObject(appModel)
                // bg-splitter連携はAppModelにネストしたObservableObjectなので、
                // 親経由では@Publishedの変更がビューに伝わらない。別途注入して直接観測させる
                // （シートはこの環境を引き継ぐので、SplitRedoSheetViewにも届く）。
                .environmentObject(appModel.bgSplitter)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    if keyCommandHandler == nil {
                        let handler = KeyCommandHandler(appModel: appModel)
                        handler.start()
                        keyCommandHandler = handler
                    }
                    appDelegate.appModel = appModel
                    appModel.openPinnedPreviewWindow = { imageId in openWindow(value: imageId) }
                }
        }
        .windowResizability(.contentSize)
        .commands { NAICullerCommands() }

        // 設定ウィンドウ（メニューから別窓。詳細設計 1章）。SwiftUIの`Settings`シーンは
        // 標準でCmd+,・アプリメニューの「設定…」に自動で紐づく。
        Settings {
            SettingsView()
                .environmentObject(appModel)
                .environmentObject(appModel.bgSplitter)
                .frame(width: 480, height: 420)
        }

        // 「この画像を固定表示」用の独立ウィンドウ（詳細は`PinnedPreviewView`）。
        // 値付き`WindowGroup(for:)`は、同じ値で`openWindow`を呼ぶと新規重複作成ではなく
        // 既存ウィンドウを前面化してくれる（画像ごとに1枚だけ開く挙動を自前実装せずに済む）。
        WindowGroup("固定表示", id: "pinnedPreview", for: Int64.self) { $imageId in
            PinnedPreviewView(imageId: imageId)
                .environmentObject(appModel)
        }

        // 独立したヘルプウィンドウ（詳細は`HelpWindowView`。実際に使ってみてのフィードバックで
        // 追加：READMEは大半の人が読まないため、アプリ内で完結した使い方説明が要ると判断した）。
        // `Window`（単一インスタンス）シーンなので、Helpメニューから何度開いても複製されず
        // 既存ウィンドウが前面化される。
        Window("ヘルプ", id: "help") {
            HelpWindowView()
                .environmentObject(appModel)
        }
    }
}

/// Appメニュー「NAICullerについて」・Helpメニューのカスタマイズ（バージョン情報とヘルプ導線）。
/// - Aboutパネルは標準の`orderFrontStandardAboutPanel`（アプリ名・バージョンはInfo.plistから
///   自動表示）に、ExifToolへの謝辞だけ`credits`として追加する簡素な構成にした
///   （ユーザーの要望：「バージョンは簡素なものでOK」）。
/// - HelpメニューはSwiftUI標準の検索欄付きメニューを`CommandGroup(replacing: .help)`で
///   置き換え、独立ヘルプウィンドウを開く項目（Cmd+?、macOS標準のヘルプショートカット）にした。
struct NAICullerCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("NAICullerについて") {
                NSApplication.shared.orderFrontStandardAboutPanel(options: [
                    NSApplication.AboutPanelOptionKey.credits: NSAttributedString(
                        string: "NovelAI生成画像のタグ付け・仕分けビューワ\n\nプロンプトの読み取り・タグの書き込みには ExifTool（Phil Harvey氏作）を利用しています。\nhttps://exiftool.org/",
                        attributes: [.font: NSFont.systemFont(ofSize: 11)]
                    ),
                ])
            }
        }
        CommandGroup(replacing: .help) {
            Button("NAICuller ヘルプ") {
                openWindow(id: "help")
            }
            // コードレビュー指摘の修正：元は`.keyboardShortcut("?", modifiers: .command)`で、
            // ショートカットが一度も発火しなかった（メニューをクリックすれば開くのに
            // Cmd+Shift+/では開かない、を実機で再現）。AppKitはキー等価をイベントの
            // `charactersIgnoringModifiers`で照合するが、US配列のCmd+Shift+/ではこれが
            // "?"ではなく"/"になるため、文字が"?"のままだと修飾キーマスクを直しても
            // 一致しない（マスクだけShift付きにする案も実機で試して駄目だった）。
            // 実際に届く文字である"/"＋[.command, .shift]で登録する。
            .keyboardShortcut("/", modifiers: [.command, .shift])
        }
    }
}
