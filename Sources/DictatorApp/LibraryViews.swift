import ApplicationServices
import DictatorCore
import SwiftUI

struct VocabularyView: View {
    @ObservedObject var model: AppModel
    @State private var newTerm = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Vocabulary").font(.dictatorDisplay(30))
                Text("Names, product terms, and jargon are sent only to your selected providers.")
                    .font(.dictatorBody(14)).foregroundStyle(.secondary)
                HStack {
                    TextField("Add a word or phrase", text: $newTerm).textFieldStyle(DictatorTextFieldStyle()).onSubmit(add)
                    Button("Add", action: add).dictatorButton()
                }
                VStack(spacing: 0) {
                    ForEach(model.data.vocabulary) { entry in
                        HStack {
                            Text(entry.value).font(.dictatorBody(14, weight: .medium))
                            Spacer()
                            Button(role: .destructive) { model.deleteVocabulary(entry.id) } label: { Image(systemName: "trash") }.dictatorButton(.destructive)
                        }.padding(.vertical, 13)
                        Divider()
                    }
                }
                if model.data.vocabulary.isEmpty { Text("Add terms that transcription models often miss.").foregroundStyle(.secondary).padding(.top, 20) }
            }
            .frame(maxWidth: DictatorDesign.contentWidth, alignment: .leading).padding(42)
        }
    }
    private func add() { model.addVocabulary(newTerm); newTerm = "" }
}

struct ClipboardView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Dictator clipboard").font(.dictatorDisplay(30))
                Text("Transcripts land here when no editable field is focused. \(model.pasteLatestShortcut.displayName) pastes the latest item.")
                    .font(.dictatorBody(14)).foregroundStyle(.secondary)
                LazyVStack(spacing: 0) {
                    ForEach(model.data.clipboard) { entry in
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(entry.text).font(.dictatorBody(14)).textSelection(.enabled)
                                Text(entry.createdAt.dictatorTimestamp).font(.dictatorUtility(9)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Paste") { Task { await model.pasteClipboard(entry) } }.dictatorButton(.secondary)
                        }.padding(.vertical, 15)
                        Divider()
                    }
                }
                if model.data.clipboard.isEmpty { Text("Nothing saved yet.").foregroundStyle(.secondary).padding(.top, 20) }
            }
            .frame(maxWidth: DictatorDesign.contentWidth, alignment: .leading).padding(42)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject private var updater: AppUpdater
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text("Settings").font(.dictatorDisplay(30))
                settingsSection("Shortcuts") {
                    shortcutRow("Dictate", detail: "Hold while speaking") {
                        ShortcutRecorder(shortcut: model.dictateShortcut, allowsFunctionModifier: true) {
                            model.setShortcut($0, for: .dictate)
                        }
                    }
                    shortcutRow("Paste latest", detail: "Paste the newest saved transcript") {
                        ShortcutRecorder(shortcut: model.pasteLatestShortcut) {
                            model.setShortcut($0, for: .pasteLatest)
                        }
                    }
                    shortcutRow("Open clipboard", detail: "Open your Dictator clipboard") {
                        ShortcutRecorder(shortcut: model.openClipboardShortcut) {
                            model.setShortcut($0, for: .openClipboard)
                        }
                    }
                    HStack {
                        Text("Click a shortcut, then press a new key combination.")
                            .font(.dictatorBody(11)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Restore defaults") { model.resetShortcuts() }.dictatorButton(.ghost)
                    }.padding(.top, 5)
                }
                settingsSection("Permissions") {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Accessibility").font(.dictatorBody(14, weight: .medium))
                            Text("Required to identify and type into the focused field.").font(.dictatorBody(12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(AXIsProcessTrusted() ? "Granted" : "Open settings") { model.requestAccessibilityPermission() }
                            .disabled(AXIsProcessTrusted()).dictatorButton(.secondary)
                    }.padding(.vertical, 11)
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Global shortcuts").font(.dictatorBody(14, weight: .medium))
                            Text("Input Monitoring lets Dictator detect your shortcuts outside the app.").font(.dictatorBody(12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(model.shortcutsAvailable ? "Working" : "Grant & retry") {
                            model.requestAccessibilityPermission()
                            model.retryShortcuts()
                        }
                        .disabled(model.shortcutsAvailable).dictatorButton(.secondary)
                    }.padding(.vertical, 11)
                }
                settingsSection("Data handling") {
                    settingRow("Transcript retention", detail: "30 days")
                    settingRow("Recordings", detail: "Sent to your provider; not stored by Dictator")
                    settingRow("Dictator telemetry", detail: "Off")
                }
                settingsSection("Updates") {
                    HStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(updater.versionDescription).font(.dictatorBody(14, weight: .medium))
                            Text("Dictator checks once a day and always asks before installing.")
                                .font(.dictatorBody(11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Check now") { updater.checkForUpdates() }
                            .disabled(!updater.canCheckForUpdates)
                            .dictatorButton(.secondary)
                    }
                    .padding(.vertical, 10)
                    .overlay(alignment: .bottom) { Divider() }
                    Toggle("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)
                        .toggleStyle(.switch).tint(DictatorDesign.signalInk)
                        .font(.dictatorBody(14, weight: .medium))
                        .padding(.vertical, 11)
                }
                settingsSection("App") {
                    Toggle("Launch Dictator at login", isOn: Binding(
                        get: { model.launchesAtLogin },
                        set: { model.setLaunchAtLogin($0) }
                    ))
                    .toggleStyle(.switch).tint(DictatorDesign.signalInk)
                    .font(.dictatorBody(14, weight: .medium))
                    .padding(.vertical, 11)
                }
                if let error = model.lastError {
                    Text(error).font(.dictatorBody(12, weight: .medium)).foregroundStyle(.orange)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .frame(maxWidth: DictatorDesign.contentWidth, alignment: .leading).padding(42)
        }
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased()).font(.dictatorUtility(9)).foregroundStyle(.secondary)
            content()
        }
    }
    private func settingRow(_ title: String, detail: String) -> some View {
        HStack { Text(title).font(.dictatorBody(14, weight: .medium)); Spacer(); Text(detail).font(.dictatorUtility(11)).foregroundStyle(.secondary) }
            .padding(.vertical, 11).overlay(alignment: .bottom) { Divider() }
    }
    private func shortcutRow<Control: View>(_ title: String, detail: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.dictatorBody(14, weight: .medium))
                Text(detail).font(.dictatorBody(11)).foregroundStyle(.secondary)
            }
            Spacer()
            control()
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Divider() }
    }
}
