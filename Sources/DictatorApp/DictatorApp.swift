import AppKit
import SwiftUI

struct MenuBarRecordingControl {
    let phase: DictationPhase

    var title: String {
        switch phase {
        case .idle: "Start Recording"
        case .listening: "Stop Recording"
        case .processing: "Transcribing…"
        }
    }

    var systemImage: String {
        switch phase {
        case .idle: "record.circle"
        case .listening: "stop.circle.fill"
        case .processing: "waveform"
        }
    }

    var isEnabled: Bool { phase != .processing }
}

@main
struct DictatorApp: App {
    @NSApplicationDelegateAdaptor(DictatorAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var updater = AppUpdater()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: model, updater: updater)
        } label: {
            Image(systemName: MenuBarRecordingControl(phase: model.phase).systemImage)
                .accessibilityLabel("Dictator")
        }
        .menuBarExtraStyle(.menu)

        Window("Dictator", id: "main") {
            MainView(model: model)
                .environmentObject(updater)
                .frame(minWidth: 920, minHeight: 620)
        }
        .defaultSize(width: 1040, height: 700)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
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
    @ObservedObject var updater: AppUpdater
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let recordingControl = MenuBarRecordingControl(phase: model.phase)
        Button(recordingControl.title, systemImage: recordingControl.systemImage) {
            Task {
                switch model.phase {
                case .idle: await model.startDictation()
                case .listening: await model.stopDictation()
                case .processing: break
                }
            }
        }
        .disabled(!recordingControl.isEnabled)
        if model.phase == .idle {
            Text(model.accessMode == .leastPrivileges
                ? "Transcript will be copied to the clipboard"
                : model.dictateInstruction)
        }
        Divider()
        Button("Open Dictator") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Divider()
        Button(model.insertionMode == .clipboard ? "Copy latest Dictator clipboard" : "Paste latest Dictator clipboard") {
            Task { await model.pasteClipboard() }
        }
        .disabled(model.data.clipboard.isEmpty)
        Divider()
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
        Divider()
        Button("Quit Dictator") { NSApp.terminate(nil) }
    }
}
