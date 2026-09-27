import DictatorCore
import SwiftUI

struct CleanupView: View {
    @Bindable var model: AppModel
    @Environment(\.undoManager) private var undoManager
    @State private var name = ""
    @State private var instruction = ""
    @State private var editingRule: RuleDraft?
    @State private var styleError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Cleanup").font(.dictatorDisplay)
                    Text("Polish every transcript with your cleanup model. Styles set the tone.")
                        .font(.dictatorBodyLarge).foregroundStyle(DictatorDesign.textSecondary)
                }
                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel("Cleanup model")
                    ProviderPicker(model: model, purpose: .cleanup, providers: CleanupProviderRegistry.metadata)
                }
                cleanupControl
                creationCard
                VStack(alignment: .leading, spacing: 18) {
                    SectionLabel("Default style")
                    stylesList
                }
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
                    Text("Clean up transcripts").font(.dictatorBody(weight: .semibold))
                    Text("Improve punctuation and apply your selected style.").font(.dictatorCaption).foregroundStyle(DictatorDesign.textSecondary)
                }
                Spacer()
                Toggle("", isOn: $model.cleanupEnabled).labelsHidden().toggleStyle(.switch).tint(DictatorDesign.signalInk)
                    .accessibilityLabel("Clean up transcripts")
            }
            Divider().overlay(DictatorDesign.border)
            VStack(alignment: .leading, spacing: 6) {
                Text("Custom instructions").font(.dictatorCaption(weight: .semibold)).foregroundStyle(DictatorDesign.textSecondary)
                Text("Optional. Tell the model how to polish transcripts—grammar, tone, phrasing. Applied on top of your selected style. Up to \(AppModel.maximumCleanupInstructionLength) characters.")
                    .font(.dictatorCaption).foregroundStyle(DictatorDesign.textSecondary)
                TextEditor(text: Binding(
                    get: { model.cleanupCustomInstruction },
                    set: { model.setCleanupCustomInstruction($0) }
                ))
                .font(.dictatorBody).frame(minHeight: 64)
                .dictatorEditor()
            }
        }
        .padding(14)
        .dictatorCard()
    }

    private var creationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("New style").font(.dictatorBodyLarge(weight: .semibold))
                Text("Tell the cleanup model how the finished transcript should sound.").font(.dictatorCaption).foregroundStyle(DictatorDesign.textSecondary)
            }
            FormField("Name") {
                TextField("e.g. Concise email", text: $name).textFieldStyle(DictatorTextFieldStyle())
            }
            FormField("Instructions") {
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
                Text(styleError).font(.dictatorCaption(weight: .medium)).foregroundStyle(DictatorDesign.textError)
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
                    Toggle("", isOn: Binding(get: { style.isEnabled }, set: { model.setStyleEnabled(style.id, $0) })).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(DictatorDesign.signalInk)
                        .accessibilityLabel("Enable \(style.name)")
                    Button("Edit") { editingRule = .style(style) }.dictatorButton(.ghost)
                        .help("Edit \(style.name)")
                    Button(role: .destructive) { model.deleteStyleWithUndo(style.id, undoManager: undoManager) } label: { Image(systemName: "trash") }.dictatorButton(.destructive)
                        .help("Delete \(style.name)")
                        .accessibilityLabel("Delete \(style.name)")
                }
            }
        }
        .dictatorCard()
    }

    private func styleRow(title: String, detail: String, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Circle().fill(selected ? DictatorDesign.accentFill : DictatorDesign.fog).frame(width: 24, height: 24)
                .overlay(Image(systemName: selected ? "checkmark" : "text.alignleft").font(DictatorDesign.glyphFont(size: 9, weight: .bold)).foregroundStyle(selected ? Color.white : DictatorDesign.textSecondary))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.dictatorBodyLarge(weight: .semibold))
                Text(detail).font(.dictatorBody).foregroundStyle(DictatorDesign.textSecondary).lineLimit(2)
            }
            Spacer()
        }.padding(.horizontal, 14).padding(.vertical, 12).contentShape(Rectangle())
    }

}
