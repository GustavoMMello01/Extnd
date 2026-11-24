import AppKit
import SwiftUI

@main
struct ExtndApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("appearance") private var appearance: ExtndAppearance = .system
    @StateObject private var session = SharingSession()

    var body: some Scene {
        Window("Extnd", id: "main") {
            HomeView(session: session)
                .tint(Color(red: 0.27, green: 0.43, blue: 0.74))
                .preferredColorScheme(appearance.colorScheme)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Picker("Appearance", selection: $appearance) {
                                Text("System").tag(ExtndAppearance.system)
                                Text("Light").tag(ExtndAppearance.light)
                                Text("Dark").tag(ExtndAppearance.dark)
                            }
                            .pickerStyle(.inline)
                        } label: {
                            Label("Appearance", systemImage: "circle.lefthalf.filled")
                        }
                        .help("Appearance")
                    }
                }
        }
        .defaultSize(width: 565, height: 430)
    }
}

private enum ExtndAppearance: String {
    case system, light, dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
