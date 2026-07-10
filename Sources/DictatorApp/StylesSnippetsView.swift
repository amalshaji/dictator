import DictatorCore
import SwiftUI

struct StylesSnippetsView: View {
    @ObservedObject var model: AppModel
    @State private var tab = 0
    @State private var name = ""
    @State private var instruction = ""
    @State private var trigger = ""
    @State private var expansion = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Styles & snippets").font(.dictatorDisplay(30))
                Text("Styles guide your selected cleanup LLM. Snippets expand locally before any text is sent.")
                    .font(.dictatorBody(14)).foregroundStyle(.secondary)
                Picker("Rule type", selection: $tab) {
                    Text("Styles").tag(0)
                    Text("Snippets").tag(1)
                }.pickerStyle(.segmented).controlSize(.small).frame(width: 270)
                if tab == 0 { styles } else { snippets }
            }
            .frame(maxWidth: DictatorDesign.contentWidth, alignment: .leading).padding(42)
        }
    }

    private var styles: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("Style name, e.g. Concise email", text: $name).textFieldStyle(DictatorTextFieldStyle())
            TextField("Instruction, e.g. Use short paragraphs and a warm professional tone", text: $instruction).textFieldStyle(DictatorTextFieldStyle())
            Button("Add style") {
                model.addStyle(name: name, instruction: instruction)
                name = ""; instruction = ""
            }.dictatorButton()
            Divider()
            Button { model.selectedStyleID = nil } label: {
                ruleRow(title: "No style", detail: "Standard cleanup", selected: model.selectedStyleID == nil)
            }.buttonStyle(.plain)
            ForEach(model.data.styles) { style in
                HStack {
                    Button { model.selectedStyleID = style.id } label: {
                        ruleRow(title: style.name, detail: style.instruction, selected: model.selectedStyleID == style.id)
                    }.buttonStyle(.plain)
                    Button(role: .destructive) { model.deleteStyle(style.id) } label: { Image(systemName: "trash") }.dictatorButton(.destructive)
                }
            }
        }
    }

    private var snippets: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("Spoken trigger, e.g. my support signature", text: $trigger).textFieldStyle(DictatorTextFieldStyle())
            TextEditor(text: $expansion).font(.dictatorBody(13)).frame(minHeight: 76)
                .dictatorEditor()
            Button("Add snippet") {
                model.addSnippet(trigger: trigger, expansion: expansion)
                trigger = ""; expansion = ""
            }.dictatorButton()
            Divider()
            ForEach(model.data.snippets) { snippet in
                HStack(alignment: .top) {
                    ruleRow(title: "“\(snippet.trigger)”", detail: snippet.expansion, selected: false)
                    Button(role: .destructive) { model.deleteSnippet(snippet.id) } label: { Image(systemName: "trash") }.dictatorButton(.destructive)
                }
            }
        }
    }

    private func ruleRow(title: String, detail: String, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Circle().fill(selected ? DictatorDesign.orchid : DictatorDesign.fog).frame(width: 24, height: 24)
                .overlay(Image(systemName: selected ? "checkmark" : "text.alignleft").font(.system(size: 9, weight: .bold)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.dictatorBody(14, weight: .semibold))
                Text(detail).font(.dictatorBody(12)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
        }.padding(.vertical, 9).contentShape(Rectangle())
    }
}
