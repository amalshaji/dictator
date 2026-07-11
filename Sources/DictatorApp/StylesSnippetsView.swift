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
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Styles & snippets").font(.dictatorDisplay(30))
                    Text("Styles guide your selected cleanup LLM. Snippets expand locally before any text is sent.")
                        .font(.dictatorBody(14)).foregroundStyle(DictatorDesign.ink.opacity(0.56))
                }
                DictatorSegmentedSwitcher(
                    label: "Rule type",
                    options: [
                        .init(title: "Styles", icon: "text.quote"),
                        .init(title: "Snippets", icon: "curlybraces")
                    ],
                    selection: $tab
                )
                if tab == 0 { styles } else { snippets }
            }
            .frame(maxWidth: DictatorDesign.contentWidth, alignment: .leading)
            .padding(.horizontal, 42).padding(.vertical, 36)
        }
    }

    private var styles: some View {
        VStack(alignment: .leading, spacing: 18) {
            creationCard(title: "New style", detail: "Tell the cleanup model how the finished transcript should sound.") {
                formField("Name") {
                    TextField("e.g. Concise email", text: $name).textFieldStyle(DictatorTextFieldStyle())
                }
                formField("Instructions") {
                    TextField("e.g. Use short paragraphs and a warm professional tone", text: $instruction).textFieldStyle(DictatorTextFieldStyle())
                }
                Button("Add style") {
                    model.addStyle(name: name, instruction: instruction)
                    name = ""; instruction = ""
                }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .dictatorButton()
            }
            sectionLabel("Your styles")
            VStack(spacing: 0) {
            Button { model.selectedStyleID = nil } label: {
                ruleRow(title: "No style", detail: "Standard cleanup", selected: model.selectedStyleID == nil)
            }.buttonStyle(.plain)
            ForEach(model.data.styles) { style in
                Divider().padding(.leading, 52)
                HStack {
                    Button { model.selectedStyleID = style.id } label: {
                        ruleRow(title: style.name, detail: style.instruction, selected: model.selectedStyleID == style.id)
                    }.buttonStyle(.plain)
                    Button(role: .destructive) { model.deleteStyle(style.id) } label: { Image(systemName: "trash") }.dictatorButton(.destructive)
                }
            }
            }
            .ruleListChrome()
        }
    }

    private var snippets: some View {
        VStack(alignment: .leading, spacing: 18) {
            creationCard(title: "New snippet", detail: "Replace a spoken phrase locally before cleanup or transcription text leaves your Mac.") {
                formField("Spoken trigger") {
                    TextField("e.g. my support signature", text: $trigger).textFieldStyle(DictatorTextFieldStyle())
                }
                formField("Replacement text") {
                    TextEditor(text: $expansion).font(.dictatorBody(13)).frame(minHeight: 76)
                        .dictatorEditor()
                }
                Button("Add snippet") {
                    model.addSnippet(trigger: trigger, expansion: expansion)
                    trigger = ""; expansion = ""
                }.disabled(trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .dictatorButton()
            }
            sectionLabel("Your snippets")
            if model.data.snippets.isEmpty {
                emptyState(icon: "curlybraces", title: "No snippets yet", detail: "Add a phrase you say often and the text it should expand into.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.data.snippets.enumerated()), id: \.element.id) { index, snippet in
                        if index > 0 { Divider().padding(.leading, 52) }
                        HStack(alignment: .top) {
                            ruleRow(title: "“\(snippet.trigger)”", detail: snippet.expansion, selected: false)
                            Button(role: .destructive) { model.deleteSnippet(snippet.id) } label: { Image(systemName: "trash") }.dictatorButton(.destructive)
                        }
                    }
                }
                .ruleListChrome()
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
        }.padding(.horizontal, 14).padding(.vertical, 12).contentShape(Rectangle())
    }

    private func creationCard<Content: View>(title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.dictatorBody(14, weight: .semibold))
                Text(detail).font(.dictatorBody(11)).foregroundStyle(DictatorDesign.muted)
            }
            content()
        }
        .padding(16)
        .background(DictatorDesign.control, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(DictatorDesign.border))
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

    private func emptyState(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(DictatorDesign.focus)
                .frame(width: 30, height: 30).background(DictatorDesign.orchid.opacity(0.38), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.dictatorBody(13, weight: .semibold))
                Text(detail).font(.dictatorBody(11)).foregroundStyle(DictatorDesign.muted)
            }
            Spacer()
        }
        .padding(14)
        .background(DictatorDesign.control, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(DictatorDesign.border))
    }
}

private extension View {
    func ruleListChrome() -> some View {
        background(DictatorDesign.control, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(DictatorDesign.border))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
