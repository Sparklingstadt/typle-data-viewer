import AppKit
import SwiftUI

@main
struct TypleDataViewerApp: App {
    @State private var model = AppModel()

    init() {
        // .app にしない実行ファイルは、これがないとウィンドウが前面に出ない
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        // Window シーンだけなら、ウィンドウを閉じるとアプリも終わる
        Window("Typle Data Viewer", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 800, minHeight: 500)
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
    }
}
