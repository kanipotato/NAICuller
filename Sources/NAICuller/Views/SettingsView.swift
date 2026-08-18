import SwiftUI
import AppKit
import NAICullerCore

/// 設定ウィンドウ：監視ルートディレクトリの追加/削除、カスタムタグのキー割当（1〜9）（詳細設計 1章）。
struct SettingsView: View {
    var body: some View {
        TabView {
            RootsSettingsTab()
                .tabItem { Label("ルート", systemImage: "folder") }
            KeyBindingsSettingsTab()
                .tabItem { Label("キー割当", systemImage: "keyboard") }
            ExifToolSettingsTab()
                .tabItem { Label("ExifTool", systemImage: "wrench.and.screwdriver") }
            BgSplitterSettingsTab()
                .tabItem { Label("背景透過・分割", systemImage: "puzzlepiece.extension") }
        }
        .padding()
    }
}
