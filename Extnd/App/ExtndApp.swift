import AppKit
import SwiftUI

@main
struct ExtndApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var session = SharingSession()

    var body: some Scene {
        Window("Extnd", id: "main") {
            HomeView(session: session)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 590, height: 550)
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
