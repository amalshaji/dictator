import ApplicationServices
import DictatorCore
import SwiftUI

struct VocabularyView: View {
    let model: AppModel
    @Environment(\.undoManager) private var undoManager
    @State private var newTerm = ""
    @State private var editing: VocabularyEntry?
    @State private var addError: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Vocabulary").font(.dictatorDisplay)
                    Text("Names, product terms, and jargon are sent only to your selected providers.")
                        .font(.dictatorBodyLarge).foregroundStyle(DictatorDesign.textSecondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Add a word or phrase", text: $newTerm).textFieldStyle(DictatorTextFieldStyle()).onSubmit(add)
                        Button("Add", action: add).dictatorButton()
                    }
                    if let addError { Text(addError).font(.dictatorCaption(weight: .medium)).foregroundStyle(DictatorDesign.textError) }
                }
                if model.data.vocabulary.isEmpty {
                    DictatorEmptyState(
                        icon: "text.book.closed",
                        title: "No vocabulary yet",
                        detail: "Add terms that transcription models often miss."
                    )
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.data.vocabulary.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { Divider().padding(.leading, 14) }
                            HStack {
                                Toggle("", isOn: Binding(get: { entry.isEnabled }, set: { model.setVocabularyEnabled(entry.id, $0) }))
                                    .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(DictatorDesign.signalInk)
                                    .accessibilityLabel("Enable \(entry.value)")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.value).font(.dictatorBodyLarge(weight: .medium))
                                    if !entry.variants.isEmpty { Text(entry.variants.joined(separator: ", ")).font(.dictatorCaption).foregroundStyle(DictatorDesign.textSecondary) }
                                }.opacity(entry.isEnabled ? 1 : 0.5)
                                Spacer()
                                Button("Edit") { editing = entry }.dictatorButton(.ghost)
                                    .help("Edit \(entry.value)")
                                Button(role: .destructive) { model.deleteVocabularyWithUndo(entry.id, undoManager: undoManager) } label: { Image(systemName: "trash") }.dictatorButton(.destructive)
                                    .help("Delete \(entry.value)")
                                    .accessibilityLabel("Delete \(entry.value)")
                            }.padding(.horizontal, 14).padding(.vertical, 11)
                        }
                    }
                    .dictatorCard()
                }
            }
            .frame(maxWidth: DictatorDesign.contentWidth, alignment: .leading)
            .padding(.horizontal, 42).padding(.vertical, 36)
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
    let model: AppModel
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
            Text("Edit vocabulary").font(.dictatorDisplay)
            TextField("Canonical term", text: $entry.value).textFieldStyle(DictatorTextFieldStyle())
            Text("Spoken variants — one per line").font(.dictatorCaption(weight: .semibold))
            TextEditor(text: $variants).frame(minHeight: 120).dictatorEditor()
            if let validationError { Text(validationError).font(.dictatorCaption(weight: .medium)).foregroundStyle(DictatorDesign.textError) }
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
