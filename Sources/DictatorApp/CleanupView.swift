import AppKit
import DictatorCore
import SwiftUI

struct CleanupView: View {
    @ObservedObject var model: AppModel
    @State private var name = ""
    @State private var instruction = ""
    @State private var editingRule: RuleDraft?
    @State private var styleError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Cleanup").font(.dictatorDisplay(30))
                    Text("Polish every transcript with your cleanup model. Styles set the tone—globally, or per app.")
                        .font(.dictatorBody(14)).foregroundStyle(DictatorDesign.inkSecondary)
                }
                cleanupControl
                creationCard
                VStack(alignment: .leading, spacing: 18) {
                    sectionLabel("Default style")
                    stylesList
                }
                VStack(alignment: .leading, spacing: 18) {
                    sectionLabel("Per-app styles")
                    perAppCard
                }
                Text("The cleanup model and API keys are configured in Providers under LLM cleanup.")
                    .font(.dictatorBody(11)).foregroundStyle(DictatorDesign.muted)
            }
            .frame(maxWidth: DictatorDesign.contentWidth, alignment: .leading)
            .padding(.horizontal, 42).padding(.vertical, 36)
        }
        .sheet(item: $editingRule) { RuleEditor(model: model, rule: $0) }
    }

    private var cleanupControl: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Clean up transcripts").font(.dictatorBody(13, weight: .semibold))
                    Text("Improve punctuation and apply your selected style.").font(.dictatorBody(11)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $model.cleanupEnabled).labelsHidden().toggleStyle(.switch).tint(DictatorDesign.signalInk)
                    .accessibilityLabel("Clean up transcripts")
            }
            Divider().overlay(DictatorDesign.border)
            VStack(alignment: .leading, spacing: 6) {
                Text("Custom instructions").font(.dictatorBody(11, weight: .semibold)).foregroundStyle(DictatorDesign.ink.opacity(0.72))
                Text("Optional. Tell the model how to polish transcripts—grammar, tone, phrasing. Applied on top of your selected style. Up to \(AppModel.maximumCleanupInstructionLength) characters.")
                    .font(.dictatorBody(11)).foregroundStyle(.secondary)
                TextEditor(text: Binding(
                    get: { model.cleanupCustomInstruction },
                    set: { model.setCleanupCustomInstruction($0) }
                ))
                .font(.dictatorBody(13)).frame(minHeight: 64)
                .dictatorEditor()
            }
        }
        .padding(14)
        .dictatorCard()
    }

    private var creationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("New style").font(.dictatorBody(14, weight: .semibold))
                Text("Tell the cleanup model how the finished transcript should sound.").font(.dictatorBody(11)).foregroundStyle(DictatorDesign.muted)
            }
            formField("Name") {
                TextField("e.g. Concise email", text: $name).textFieldStyle(DictatorTextFieldStyle())
            }
            formField("Instructions") {
                TextField("e.g. Use short paragraphs and a warm professional tone", text: $instruction).textFieldStyle(DictatorTextFieldStyle())
            }
            Button("Add style") {
                do {
                    try model.saveStyle(.init(name: name, instruction: instruction))
                    name = ""; instruction = ""; styleError = nil
                } catch { styleError = error.localizedDescription }
            }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .dictatorButton()
            if let styleError {
                Text(styleError).font(.dictatorBody(11, weight: .medium)).foregroundStyle(.red)
            }
        }
        .padding(16)
        .dictatorCard()
    }

    private var stylesList: some View {
        VStack(spacing: 0) {
            Button { model.selectedStyleID = nil } label: {
                styleRow(title: "No style", detail: "Standard cleanup", selected: model.selectedStyleID == nil)
            }.buttonStyle(.plain)
            ForEach(model.data.styles) { style in
                Divider().padding(.leading, 52)
                HStack {
                    Button { model.selectStyle(style.id) } label: {
                        styleRow(title: style.name, detail: style.instruction, selected: model.selectedStyleID == style.id)
                    }.buttonStyle(.plain).disabled(!style.isEnabled).opacity(style.isEnabled ? 1 : 0.5)
                    Toggle("", isOn: Binding(get: { style.isEnabled }, set: { model.setStyleEnabled(style.id, $0) })).labelsHidden().toggleStyle(.switch).tint(DictatorDesign.signalInk)
                        .accessibilityLabel("Enable \(style.name)")
                    Button("Edit") { editingRule = .style(style) }.dictatorButton(.ghost)
                    Button(role: .destructive) { model.deleteStyle(style.id) } label: { Image(systemName: "trash") }.dictatorButton(.destructive)
                        .accessibilityLabel("Delete \(style.name)")
                }
            }
        }
        .dictatorCard()
    }

    private var perAppCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Text("Apps below use their assigned style instead of the default.")
                    .font(.dictatorBody(11)).foregroundStyle(.secondary)
                Spacer()
                addAppMenu
            }
            if model.data.appStyleOverrides.isEmpty {
                Text(enabledStyles.isEmpty
                    ? "Create a style first, then assign it to an app."
                    : "No app overrides yet. Add an app to give it its own style—formal for email, casual for chat.")
                    .font(.dictatorBody(12)).foregroundStyle(DictatorDesign.muted)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(sortedOverrides.enumerated()), id: \.element.bundleID) { index, override in
                        if index > 0 { Divider() }
                        perAppRow(override)
                    }
                }
            }
        }
        .padding(14)
        .dictatorCard()
    }

    private func perAppRow(_ override: AppStyleRow) -> some View {
        HStack(spacing: 12) {
            HomeApplicationIcon(identity: override.identity, size: 24)
            Text(override.identity.name).font(.dictatorBody(13, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 12)
            DictatorMenuField(
                label: "Style for \(override.identity.name)",
                options: enabledStyles.map { .init(value: $0.id.uuidString, label: $0.name) },
                selection: Binding(
                    get: { override.styleID.uuidString },
                    set: { value in
                        guard let id = UUID(uuidString: value) else { return }
                        model.assignStyle(id, toApp: override.bundleID)
                    }
                )
            )
            .frame(width: 190)
            Button(role: .destructive) { model.removeAppStyleOverride(override.bundleID) } label: { Image(systemName: "trash") }.dictatorButton(.destructive)
                .accessibilityLabel("Remove style override for \(override.identity.name)")
        }
        .padding(.vertical, 8)
    }

    private var addAppMenu: some View {
        Menu {
            ForEach(candidateApps, id: \.bundleID) { app in
                Button(app.name) { addOverride(for: app.bundleID) }
            }
        } label: {
            Label("Add app", systemImage: "plus")
                .font(.dictatorBody(12, weight: .semibold))
                .foregroundStyle(DictatorDesign.ink)
                .padding(.horizontal, 11)
                .frame(height: 30)
                .background(DictatorDesign.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(DictatorDesign.border))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(enabledStyles.isEmpty || candidateApps.isEmpty)
        .accessibilityLabel("Add per-app style override")
    }

    private struct AppStyleRow {
        let bundleID: String
        let styleID: UUID
        let identity: HomeApplicationIdentity
    }

    private var sortedOverrides: [AppStyleRow] {
        model.data.appStyleOverrides
            .map { AppStyleRow(bundleID: $0.key, styleID: $0.value, identity: HomeApplicationIdentity(bundleIdentifier: $0.key)) }
            .sorted { $0.identity.name.localizedCaseInsensitiveCompare($1.identity.name) == .orderedAscending }
    }

    private var enabledStyles: [WritingStyle] {
        model.data.styles.filter(\.isEnabled)
    }

    private var candidateApps: [(bundleID: String, name: String)] {
        var seen = Set<String>()
        var apps: [(String, String)] = []
        let overridden = model.data.appStyleOverrides
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
        for app in running {
            guard let id = app.bundleIdentifier,
                  id != Bundle.main.bundleIdentifier,
                  overridden[id] == nil,
                  seen.insert(id).inserted
            else { continue }
            apps.append((id, app.localizedName ?? HomeApplicationIdentity(bundleIdentifier: id).name))
        }
        for record in model.data.transcripts {
            guard let id = record.sourceBundleID,
                  overridden[id] == nil,
                  seen.insert(id).inserted
            else { continue }
            apps.append((id, HomeApplicationIdentity(bundleIdentifier: id).name))
        }
        return apps
            .map { (bundleID: $0.0, name: $0.1) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func addOverride(for bundleID: String) {
        let defaultStyle = enabledStyles.first { $0.id == model.selectedStyleID } ?? enabledStyles.first
        guard let defaultStyle else { return }
        model.assignStyle(defaultStyle.id, toApp: bundleID)
    }

    private func styleRow(title: String, detail: String, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Circle().fill(selected ? DictatorDesign.orchid : DictatorDesign.fog).frame(width: 24, height: 24)
                .overlay(Image(systemName: selected ? "checkmark" : "text.alignleft").font(.system(size: 9, weight: .bold)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.dictatorBody(14, weight: .semibold))
                Text(detail).font(.dictatorBody(12)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
        }.padding(.horizontal, 14).padding(.vertical, 12).contentShape(Rectangle())
    }

    private func formField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.dictatorBody(11, weight: .semibold)).foregroundStyle(DictatorDesign.ink.opacity(0.72))
            content()
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased()).font(.dictatorUtility(9)).foregroundStyle(DictatorDesign.muted)
    }
}
