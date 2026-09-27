import AppKit
import SwiftUI

struct MenuBarRecordingControl {
    let phase: DictationPhase

    var title: String {
        switch phase {
        case .idle: "Start Dictation"
        case .listening: "Stop Dictation"
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
    @State private var model = AppModel()
    @State private var updater = AppUpdater()
    @State private var navigation = NavigationModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: model, updater: updater)
        } label: {
            Image(systemName: MenuBarRecordingControl(phase: model.phase).systemImage)
                .accessibilityLabel("Dictator")
                .onAppear {
                    appDelegate.onTerminate = { await model.flushPersistence() }
                }
        }
        .menuBarExtraStyle(.menu)

        Window("Dictator", id: "main") {
            MainView(model: model)
                .environment(updater)
                .environment(navigation)
                .frame(minWidth: 920, minHeight: 620)
        }
        .defaultSize(width: 1040, height: 700)
        .windowResizability(.contentMinSize)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    navigation.destination = .settings
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Dictation") {
                Button("Cancel Dictation") { model.cancelDictation() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(model.phase != .listening)
            }
            CommandGroup(after: .sidebar) {
                ForEach(Destination.allCases) { destination in
                    Button(destination.rawValue) { navigation.destination = destination }
                        .keyboardShortcut(KeyEquivalent(Character("\(destination.keyboardNumber)")), modifiers: .command)
                }
            }
        }
    }
}

private final class DictatorAppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (() async -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        } else {
            NSApp.applicationIconImage = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        }
    }

    /// Flushes any debounced local-data write before the app actually quits.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let onTerminate else { return .terminateNow }
        Task {
            await onTerminate()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

private struct MenuBarContent: View {
    let model: AppModel
    let updater: AppUpdater
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let recordingControl = MenuBarRecordingControl(phase: model.phase)
        let recordButton = Button(recordingControl.title, systemImage: recordingControl.systemImage) {
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
            Section(model.accessMode == .leastPrivileges
                ? "Transcript will be copied to the clipboard"
                : model.dictateInstruction) {
                recordButton
            }
        } else {
            recordButton
        }
        Divider()
        Button("Open Dictator") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Divider()
        Button(model.insertionMode == .clipboard ? "Copy latest transcript" : "Paste latest transcript") {
            Task { await model.pasteClipboard() }
        }
        .disabled(model.data.transcripts.isEmpty)
        Divider()
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
        Divider()
        Button("Quit Dictator") { NSApp.terminate(nil) }
    }
}
