import DictatorCore
import SwiftUI

enum RuleDraft: Identifiable {
    case style(WritingStyle)
    case snippet(SnippetEntry)

    var id: UUID {
        switch self {
        case .style(let style): style.id
        case .snippet(let snippet): snippet.id
        }
    }

    var title: String {
        switch self {
        case .style: "Edit style"
        case .snippet: "Edit snippet"
        }
    }

    var primaryLabel: String {
        switch self {
        case .style: "Name"
        case .snippet: "Trigger"
        }
    }
}

struct RuleEditor: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    private let rule: RuleDraft
    @State private var primary: String
    @State private var secondary: String
    @State private var validationError: String?

    init(model: AppModel, rule: RuleDraft) {
        self.model = model
        self.rule = rule
        switch rule {
        case .style(let style):
            _primary = State(initialValue: style.name)
            _secondary = State(initialValue: style.instruction)
        case .snippet(let snippet):
            _primary = State(initialValue: snippet.trigger)
            _secondary = State(initialValue: snippet.expansion)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(rule.title).font(.dictatorDisplay(22))
            TextField(rule.primaryLabel, text: $primary).textFieldStyle(DictatorTextFieldStyle())
            TextEditor(text: $secondary).frame(minHeight: 120).dictatorEditor()
            if let validationError { Text(validationError).font(.dictatorBody(11, weight: .medium)).foregroundStyle(.red) }
            HStack { Spacer(); Button("Cancel") { dismiss() }.dictatorButton(.ghost); Button("Save") {
                do {
                    switch rule {
                    case .style(var style):
                        style.name = primary; style.instruction = secondary
                        try model.saveStyle(style)
                    case .snippet(var snippet):
                        snippet.trigger = primary; snippet.expansion = secondary
                        try model.saveSnippet(snippet)
                    }
                    dismiss()
                } catch { validationError = error.localizedDescription }
            }.dictatorButton() }
        }.padding(24).frame(width: 460)
    }
}
