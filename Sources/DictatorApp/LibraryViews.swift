import ApplicationServices
import DictatorCore
import SwiftUI

struct VocabularyView: View {
    @ObservedObject var model: AppModel
    @State private var newTerm = ""
    @State private var editing: VocabularyEntry?
    @State private var addError: String?
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
                if let addError { Text(addError).font(.dictatorBody(11, weight: .medium)).foregroundStyle(.red) }
                VStack(spacing: 0) {
                    ForEach(model.data.vocabulary) { entry in
                        HStack {
                            Toggle("", isOn: Binding(get: { entry.isEnabled }, set: { model.setVocabularyEnabled(entry.id, $0) }))
                                .labelsHidden().toggleStyle(.switch)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.value).font(.dictatorBody(14, weight: .medium))
                                if !entry.variants.isEmpty { Text(entry.variants.joined(separator: ", ")).font(.dictatorBody(11)).foregroundStyle(.secondary) }
                            }.opacity(entry.isEnabled ? 1 : 0.5)
                            Spacer()
                            Button("Edit") { editing = entry }.dictatorButton(.ghost)
                            Button(role: .destructive) { model.deleteVocabulary(entry.id) } label: { Image(systemName: "trash") }.dictatorButton(.destructive)
                        }.padding(.vertical, 13)
                        Divider()
                    }
                }
                if model.data.vocabulary.isEmpty { Text("Add terms that transcription models often miss.").foregroundStyle(.secondary).padding(.top, 20) }
            }
            .frame(maxWidth: DictatorDesign.contentWidth, alignment: .leading).padding(42)
        }
        .sheet(item: $editing) { entry in VocabularyEditor(model: model, entry: entry) }
    }
    private func add() {
        do {
            try model.saveVocabulary(.init(value: newTerm))
            newTerm = ""
            addError = nil
        } catch {
            addError = error.localizedDescription
        }
    }
}

private struct VocabularyEditor: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var entry: VocabularyEntry
    @State private var variants: String
    @State private var validationError: String?

    init(model: AppModel, entry: VocabularyEntry) {
        self.model = model
        _entry = State(initialValue: entry)
        _variants = State(initialValue: entry.variants.joined(separator: "\n"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit vocabulary").font(.dictatorDisplay(22))
            TextField("Canonical term", text: $entry.value).textFieldStyle(DictatorTextFieldStyle())
            Text("Spoken variants — one per line").font(.dictatorBody(11, weight: .semibold))
            TextEditor(text: $variants).frame(minHeight: 120).dictatorEditor()
            if let validationError { Text(validationError).font(.dictatorBody(11, weight: .medium)).foregroundStyle(.red) }
            HStack { Spacer(); Button("Cancel") { dismiss() }.dictatorButton(.ghost); Button("Save") {
                entry.variants = variants.components(separatedBy: .newlines)
                do {
                    try model.saveVocabulary(entry)
                    dismiss()
                } catch {
                    validationError = error.localizedDescription
                }
            }.dictatorButton() }
        }.padding(24).frame(width: 460)
    }
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
                    shortcutRow("Screen aware", detail: "Hold while speaking about the focused window") {
                        Text(GlobalShortcut.screenAware.displayName)
                            .font(.dictatorUtility(12)).foregroundStyle(DictatorDesign.ink)
                            .padding(.horizontal, 12).frame(height: 30)
                            .background(DictatorDesign.control, in: RoundedRectangle(cornerRadius: 8))
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
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Screen Recording").font(.dictatorBody(14, weight: .medium))
                            Text("Required only for focused-window screen-aware dictation.").font(.dictatorBody(12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(model.screenCaptureGranted ? "Granted" : "Grant permission") {
                            model.requestScreenCapturePermission()
                        }
                        .disabled(model.screenCaptureGranted).dictatorButton(.secondary)
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
                    HStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Status pill").font(.dictatorBody(14, weight: .medium))
                            Text("Choose where status appears in every dictation mode.")
                                .font(.dictatorBody(11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        DictatorSegmentedSwitcher(
                            label: "Status pill position",
                            options: [
                                .init(title: "Notch", icon: "rectangle.topthird.inset.filled"),
                                .init(title: "Next to pointer", icon: "cursorarrow"),
                            ],
                            selection: Binding(
                                get: { model.hudPositionMode == .notch ? 0 : 1 },
                                set: { model.setHUDPositionMode($0 == 0 ? .notch : .pointer) }
                            )
                        )
                    }
                    .padding(.vertical, 10)
                    .overlay(alignment: .bottom) { Divider() }
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
