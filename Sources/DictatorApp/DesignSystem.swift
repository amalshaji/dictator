import SwiftUI

enum DictatorDesign {
    static let ink = Color(red: 23/255, green: 21/255, blue: 26/255)
    static let paper = Color(red: 246/255, green: 244/255, blue: 240/255)
    static let fog = Color(red: 232/255, green: 228/255, blue: 222/255)
    static let orchid = Color(red: 215/255, green: 183/255, blue: 255/255)
    static let signalInk = Color(red: 49/255, green: 36/255, blue: 62/255)
    static let white = Color.white
    static let control = Color.white
    static let border = Color(red: 217/255, green: 213/255, blue: 207/255)
    static let muted = Color(red: 111/255, green: 106/255, blue: 115/255)
    static let focus = Color(red: 110/255, green: 76/255, blue: 135/255)

    static let sidebarWidth: CGFloat = 184
    static let contentWidth: CGFloat = 760
    static let cornerRadius: CGFloat = 14
}

enum DictatorButtonKind { case primary, secondary, ghost, destructive }

struct DictatorSegmentedSwitcher: View {
    struct Option {
        let title: String
        let icon: String
    }

    let label: String
    let options: [Option]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options.indices, id: \.self) { index in
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { selection = index }
                } label: {
                    Label(options[index].title, systemImage: options[index].icon)
                        .font(.dictatorBody(12, weight: .semibold))
                        .foregroundStyle(selection == index ? DictatorDesign.ink : DictatorDesign.muted)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .contentShape(Rectangle())
                        .background(selection == index ? DictatorDesign.control : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .shadow(color: selection == index ? .black.opacity(0.06) : .clear, radius: 2, y: 1)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == index ? .isSelected : [])
            }
        }
        .padding(3)
        .background(DictatorDesign.fog.opacity(0.8), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(DictatorDesign.border.opacity(0.7)))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

struct DictatorButtonStyle: ButtonStyle {
    let kind: DictatorButtonKind
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.dictatorBody(12.5, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, kind == .ghost ? 8 : 13)
            .frame(minHeight: 34)
            .background(background(configuration.isPressed), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                if kind == .secondary {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(DictatorDesign.border, lineWidth: 1)
                }
            }
            .opacity(isEnabled ? 1 : 0.46)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch kind {
        case .primary: .white
        case .secondary, .ghost: DictatorDesign.ink
        case .destructive: .red
        }
    }

    private func background(_ pressed: Bool) -> Color {
        switch kind {
        case .primary: pressed ? DictatorDesign.signalInk.opacity(0.86) : DictatorDesign.signalInk
        case .secondary: pressed ? DictatorDesign.fog : DictatorDesign.control
        case .ghost: pressed ? DictatorDesign.fog : .clear
        case .destructive: pressed ? Color.red.opacity(0.12) : .clear
        }
    }
}

struct DictatorTextFieldStyle: TextFieldStyle {
    @Environment(\.isFocused) private var isFocused

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(.dictatorBody(13))
            .padding(.horizontal, 11)
            .frame(height: 36)
            .background(DictatorDesign.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(isFocused ? DictatorDesign.focus : DictatorDesign.border, lineWidth: isFocused ? 1.5 : 1))
            .shadow(color: isFocused ? DictatorDesign.focus.opacity(0.16) : .clear, radius: 0, x: 0, y: 0)
            .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}

struct DictatorMenuOption: Identifiable {
    let value: String
    let label: String

    var id: String { value }
}

struct DictatorMenuField: View {
    let label: String
    let options: [DictatorMenuOption]
    @Binding var selection: String

    var body: some View {
        Menu {
            ForEach(options) { option in
                Button {
                    selection = option.value
                } label: {
                    if option.value == selection {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Text(selectedLabel)
                    .font(.dictatorBody(13))
                    .foregroundStyle(DictatorDesign.ink)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DictatorDesign.muted)
            }
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .contentShape(Rectangle())
            .background(DictatorDesign.fog.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(DictatorDesign.border))
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(label)
        .accessibilityValue(selectedLabel)
    }

    private var selectedLabel: String {
        options.first(where: { $0.value == selection })?.label ?? selection
    }
}

struct DictatorEditorChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .padding(9)
            .background(DictatorDesign.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(DictatorDesign.border, lineWidth: 1))
    }
}

extension View {
    func dictatorButton(_ kind: DictatorButtonKind = .primary) -> some View { buttonStyle(DictatorButtonStyle(kind: kind)) }
    func dictatorEditor() -> some View { modifier(DictatorEditorChrome()) }
}

extension Font {
    static func dictatorDisplay(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
    static func dictatorBody(_ size: CGFloat, weight: Weight = .regular) -> Font { .system(size: size, weight: weight, design: .default) }
    static func dictatorUtility(_ size: CGFloat) -> Font { .system(size: size, weight: .medium, design: .default) }
}

extension Date {
    var dictatorTimestamp: String {
        let time = formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(self) { return "Today, \(time)" }
        if Calendar.current.isDateInYesterday(self) { return "Yesterday, \(time)" }
        return formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}
