import AppKit
import SwiftUI

@main
struct DictatorApp: App {
    @NSApplicationDelegateAdaptor(DictatorAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("Dictator", systemImage: "waveform") {
            MenuBarContent(model: model)
        }
        .menuBarExtraStyle(.menu)

        Window("Dictator", id: "main") {
            MainView(model: model)
                .frame(minWidth: 920, minHeight: 620)
        }
        .defaultSize(width: 1040, height: 700)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenu("Dictation") {
                Button("Cancel dictation") { model.cancelDictation() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
        }
    }
}

private final class DictatorAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        } else {
            NSApp.applicationIconImage = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        }
    }
}

private struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Dictator") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Divider()
        Text(model.phase == .listening ? "Listening…" : "Hold \(model.dictateShortcut.displayName) to dictate")
        Button("Paste latest Dictator clipboard") { Task { await model.pasteClipboard() } }
            .disabled(model.data.clipboard.isEmpty)
        Divider()
        Button("Quit Dictator") { NSApp.terminate(nil) }
    }
}
