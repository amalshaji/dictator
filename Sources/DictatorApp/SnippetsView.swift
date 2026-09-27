import DictatorCore
import SwiftUI

struct SnippetsView: View {
    let model: AppModel
    @Environment(\.undoManager) private var undoManager
    @State private var trigger = ""
    @State private var expansion = ""
    @State private var editingRule: RuleDraft?
    @State private var snippetError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Snippets").font(.dictatorDisplay)
                    Text("Say a trigger phrase and it expands locally before any text is sent.")
                        .font(.dictatorBodyLarge).foregroundStyle(DictatorDesign.textSecondary)
                }
                creationCard
                SectionLabel("Your snippets")
                if model.data.snippets.isEmpty {
                    DictatorEmptyState(icon: "curlybraces", title: "No snippets yet", detail: "Add a phrase you say often and the text it should expand into.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.data.snippets.enumerated()), id: \.element.id) { index, snippet in
                            if index > 0 { Divider().padding(.leading, 52) }
                            HStack(alignment: .top) {
                                snippetRow(snippet)
                                Toggle("", isOn: Binding(get: { snippet.isEnabled }, set: { model.setSnippetEnabled(snippet.id, $0) })).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(DictatorDesign.signalInk)
                                    .accessibilityLabel("Enable \(snippet.trigger)")
                                Button("Edit") { editingRule = .snippet(snippet) }.dictatorButton(.ghost)
                                    .help("Edit \(snippet.trigger)")
                                Button(role: .destructive) { model.deleteSnippetWithUndo(snippet.id, undoManager: undoManager) } label: { Image(systemName: "trash") }.dictatorButton(.destructive)
                                    .help("Delete \(snippet.trigger)")
                                    .accessibilityLabel("Delete \(snippet.trigger)")
                            }
                        }
                    }
                    .dictatorCard()
                }
            }
            .frame(maxWidth: DictatorDesign.contentWidth, alignment: .leading)
            .padding(.horizontal, 42).padding(.vertical, 36)
        }
        .sheet(item: $editingRule) { RuleEditor(model: model, rule: $0) }
    }

    private var creationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("New snippet").font(.dictatorBodyLarge(weight: .semibold))
                Text("Replace a spoken phrase locally before cleanup or transcription text leaves your Mac.").font(.dictatorCaption).foregroundStyle(DictatorDesign.textSecondary)
            }
            FormField("Spoken trigger") {
                TextField("e.g. my support signature", text: $trigger).textFieldStyle(DictatorTextFieldStyle())
            }
            FormField("Replacement text") {
                TextEditor(text: $expansion).font(.dictatorBody).frame(minHeight: 76)
                    .dictatorEditor()
            }
            Button("Add snippet") {
                do {
                    try model.saveSnippet(.init(trigger: trigger, expansion: expansion))
                    trigger = ""; expansion = ""; snippetError = nil
                } catch { snippetError = error.localizedDescription }
            }.disabled(trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .dictatorButton()
            if let snippetError {
                Text(snippetError).font(.dictatorCaption(weight: .medium)).foregroundStyle(DictatorDesign.textError)
            }
        }
        .padding(16)
        .dictatorCard()
    }

    private func snippetRow(_ snippet: SnippetEntry) -> some View {
        HStack(spacing: 12) {
            Circle().fill(DictatorDesign.fog).frame(width: 24, height: 24)
                .overlay(Image(systemName: "curlybraces").font(DictatorDesign.glyphFont(size: 9, weight: .bold)))
            VStack(alignment: .leading, spacing: 3) {
                Text("“\(snippet.trigger)”").font(.dictatorBodyLarge(weight: .semibold))
                Text(snippet.expansion).font(.dictatorBody).foregroundStyle(DictatorDesign.textSecondary).lineLimit(2)
            }
            Spacer()
        }.padding(.horizontal, 14).padding(.vertical, 12).contentShape(Rectangle())
    }

}
