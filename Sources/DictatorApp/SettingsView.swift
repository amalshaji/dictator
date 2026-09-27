import ApplicationServices
import DictatorCore
import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @Environment(AppUpdater.self) private var updater: AppUpdater
    var body: some View {
        @Bindable var updater = updater
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text("Settings").font(.dictatorDisplay)
                settingsSection("Access mode") {
                    HStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.accessMode.title).font(.dictatorBodyLarge(weight: .medium))
                            Text(model.accessMode.detail)
                                .font(.dictatorCaption).foregroundStyle(DictatorDesign.textSecondary)
                        }
                        Spacer()
                        DictatorSegmentedSwitcher(
                            label: "Access mode",
                            options: [
                                .init(title: "Least privileges", icon: "hand.raised"),
                                .init(title: "System-wide", icon: "keyboard"),
                            ],
                            selection: Binding(
                                get: { model.accessMode == .leastPrivileges ? 0 : 1 },
                                set: { model.setAccessMode($0 == 0 ? .leastPrivileges : .systemWide) }
                            )
                        )
                    }
                    .padding(.vertical, 10)
                    .overlay(alignment: .bottom) { Divider() }
                }
                if model.accessMode == .systemWide {
                    settingsSection("Shortcuts") {
                    shortcutRow(
                        "Dictate",
                        detail: model.dictateActivationMode == .hold
                            ? "Hold while speaking"
                            : "Press to start, press again to stop"
                    ) {
                        ShortcutRecorder(shortcut: model.dictateShortcut, allowsFunctionModifier: true) {
                            model.setShortcut($0, for: .dictate)
                        }
                    }
                    shortcutRow("Dictate behavior", detail: "Choose how the dictate shortcut starts and stops recording.") {
                        DictatorSegmentedSwitcher(
                            label: "Dictate shortcut behavior",
                            options: [
                                .init(title: "Hold", icon: "hand.tap"),
                                .init(title: "Toggle", icon: "arrow.triangle.2.circlepath"),
                            ],
                            selection: Binding(
                                get: { model.dictateActivationMode == .hold ? 0 : 1 },
                                set: { model.setDictateActivationMode($0 == 0 ? .hold : .toggle) }
                            )
                        )
                    }
                    shortcutRow("Paste latest", detail: "Paste the newest saved transcript") {
                        ShortcutRecorder(shortcut: model.pasteLatestShortcut) {
                            model.setShortcut($0, for: .pasteLatest)
                        }
                    }
                    HStack {
                        Text("Click a shortcut, then press a new key combination.")
                            .font(.dictatorCaption).foregroundStyle(DictatorDesign.textSecondary)
                        Spacer()
                        Button("Restore defaults") { model.resetShortcuts() }
                            .dictatorButton(.ghost)
                            // Ghost buttons draw no background, so cancel the style's
                            // horizontal padding to sit the label on the same edge.
                            .padding(.trailing, -8)
                    }.padding(.top, 5)
                    }
                }
                settingsSection("Permissions") {
                    PermissionRow(
                        title: "Microphone",
                        detail: "Used only while you explicitly record audio for transcription.",
                        granted: model.microphoneGranted,
                        actionTitle: model.microphoneGranted ? "Granted" : "Allow microphone",
                        action: { Task { await model.requestMicrophonePermission() } }
                    )
                    if model.accessMode == .leastPrivileges {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Result delivery").font(.dictatorBodyLarge(weight: .medium))
                                Text("Transcripts are copied to the clipboard. Press ⌘V to paste; no administrative settings are needed.")
                                    .font(.dictatorBody).foregroundStyle(DictatorDesign.textSecondary)
                            }
                            Spacer()
                            Label("Clipboard", systemImage: "doc.on.clipboard")
                                .font(.dictatorBody(weight: .semibold))
                                .foregroundStyle(DictatorDesign.accentForeground)
                        }.padding(.vertical, 11)
                    } else {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Result delivery").font(.dictatorBodyLarge(weight: .medium))
                            Text(model.insertionMode == .clipboard
                                ? "Results are copied to the clipboard—press ⌘V to paste. No Accessibility permission needed."
                                : "Results are inserted into the focused field. Requires Accessibility.")
                                .font(.dictatorBody).foregroundStyle(DictatorDesign.textSecondary)
                        }
                        Spacer()
                        DictatorSegmentedSwitcher(
                            label: "Result delivery",
                            options: [
                                .init(title: "Insert", icon: "text.cursor"),
                                .init(title: "Copy", icon: "doc.on.clipboard"),
                            ],
                            selection: Binding(
                                get: { model.insertionMode == .insert ? 0 : 1 },
                                set: { model.setInsertionMode($0 == 0 ? .insert : .clipboard) }
                            )
                        )
                    }.padding(.vertical, 11)
                    PermissionRow(
                        title: "Accessibility",
                        detail: model.insertionMode == .clipboard
                            ? "Not needed while results are delivered through the clipboard."
                            : "Required to identify and type into the focused field.",
                        granted: AXIsProcessTrusted(),
                        actionTitle: AXIsProcessTrusted() ? "Granted" : "Open settings",
                        action: { model.requestAccessibilityPermission() }
                    )
                    PermissionRow(
                        title: "Global shortcuts",
                        detail: "Input Monitoring lets Dictator detect your shortcuts outside the app.",
                        granted: model.shortcutsAvailable,
                        actionTitle: model.shortcutsAvailable ? "Working" : "Grant & retry",
                        action: { model.requestInputMonitoringPermission() }
                    )
                    }
                }
                settingsSection("Data handling") {
                    settingRow("Transcript retention", detail: "30 days")
                    settingRow("Recordings", detail: "Sent to your provider; not stored by Dictator")
                    settingRow("Dictator telemetry", detail: "Off")
                }
                settingsSection("Updates") {
                    HStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(updater.versionDescription).font(.dictatorBodyLarge(weight: .medium))
                            Text("Dictator checks once a day and always asks before installing.")
                                .font(.dictatorCaption).foregroundStyle(DictatorDesign.textSecondary)
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
                        .font(.dictatorBodyLarge(weight: .medium))
                        .padding(.vertical, 11)
                        .overlay(alignment: .bottom) { Divider() }
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Receive canary updates", isOn: $updater.receivesCanaryUpdates)
                            .toggleStyle(.switch).tint(DictatorDesign.signalInk)
                            .font(.dictatorBodyLarge(weight: .medium))
                        Text("Early builds from successful main merges may be unstable. Turning this off does not downgrade the installed app.")
                            .font(.dictatorCaption).foregroundStyle(DictatorDesign.textSecondary)
                    }
                    .padding(.vertical, 11)
                }
                settingsSection("App") {
                    HStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Status pill").font(.dictatorBodyLarge(weight: .medium))
                            Text("Appears below the notch or menu bar on the display where recording starts.")
                                .font(.dictatorCaption).foregroundStyle(DictatorDesign.textSecondary)
                        }
                        Spacer()
                        Label("Top center", systemImage: "rectangle.topthird.inset.filled")
                            .font(.dictatorBody(weight: .semibold))
                            .foregroundStyle(DictatorDesign.accentForeground)
                    }
                    .padding(.vertical, 10)
                    .overlay(alignment: .bottom) { Divider() }
                    Toggle("Launch Dictator at login", isOn: Binding(
                        get: { model.launchesAtLogin },
                        set: { model.setLaunchAtLogin($0) }
                    ))
                    .toggleStyle(.switch).tint(DictatorDesign.signalInk)
                    .font(.dictatorBodyLarge(weight: .medium))
                    .padding(.vertical, 11)
                }
                if let error = model.lastError {
                    Text(error).font(.dictatorBody(weight: .medium)).foregroundStyle(DictatorDesign.textError)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(DictatorDesign.textError.opacity(0.08), in: RoundedRectangle(cornerRadius: DictatorDesign.radiusCard, style: .continuous))
                }
            }
            .frame(maxWidth: DictatorDesign.contentWidth, alignment: .leading)
            .padding(.horizontal, 42).padding(.vertical, 36)
        }
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel(title)
            content()
        }
    }
    private func settingRow(_ title: String, detail: String) -> some View {
        HStack { Text(title).font(.dictatorBodyLarge(weight: .medium)); Spacer(); Text(detail).font(.dictatorCaption(weight: .medium)).foregroundStyle(DictatorDesign.textSecondary) }
            .padding(.vertical, 11).overlay(alignment: .bottom) { Divider() }
    }
    private func shortcutRow<Control: View>(_ title: String, detail: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.dictatorBodyLarge(weight: .medium))
                Text(detail).font(.dictatorCaption).foregroundStyle(DictatorDesign.textSecondary)
            }
            Spacer()
            control()
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Divider() }
    }
}
