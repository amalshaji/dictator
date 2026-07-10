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
    static func dictatorUtility(_ size: CGFloat) -> Font { .system(size: size, weight: .medium, design: .monospaced) }
}

extension Date {
    var dictatorTimestamp: String {
        let time = formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(self) { return "Today, \(time)" }
        if Calendar.current.isDateInYesterday(self) { return "Yesterday, \(time)" }
        return formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}
