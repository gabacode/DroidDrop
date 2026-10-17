import AppKit
import SwiftUI

@main
struct DroidDropApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("DroidDrop", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 720, minHeight: 440)
        }
        .defaultSize(width: 900, height: 560)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
