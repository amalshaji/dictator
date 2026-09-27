import SwiftUI

extension Color {
    /// Builds a `Color` that tracks the current appearance, resolving to `dark` under Dark
    /// Mode and to `light` otherwise. Backed by a dynamic `NSColor` so SwiftUI, AppKit
    /// drawing, and window chrome all see the same live-updating value.
    init(light: NSColor, dark: NSColor) {
        self.init(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

enum DictatorDesign {
    static let ink = Color(
        light: NSColor(red: 23/255, green: 21/255, blue: 26/255, alpha: 1),
        dark: NSColor(red: 240/255, green: 238/255, blue: 234/255, alpha: 1)
    )
    static let paper = Color(
        light: NSColor(red: 246/255, green: 244/255, blue: 240/255, alpha: 1),
        dark: NSColor(red: 28/255, green: 27/255, blue: 31/255, alpha: 1)
    )
    static let fog = Color(
        light: NSColor(red: 232/255, green: 228/255, blue: 222/255, alpha: 1),
        dark: NSColor(red: 38/255, green: 36/255, blue: 42/255, alpha: 1)
    )
    static let orchid = Color(
        light: NSColor(red: 215/255, green: 183/255, blue: 255/255, alpha: 1),
        dark: NSColor(red: 196/255, green: 165/255, blue: 232/255, alpha: 1)
    )
    static let signalInk = Color(
        light: NSColor(red: 49/255, green: 36/255, blue: 62/255, alpha: 1),
        dark: NSColor(red: 96/255, green: 72/255, blue: 140/255, alpha: 1)
    )
    static let control = Color(
        light: NSColor.white,
        dark: NSColor(red: 46/255, green: 44/255, blue: 51/255, alpha: 1)
    )
    static let border = Color(
        light: NSColor(red: 217/255, green: 213/255, blue: 207/255, alpha: 1),
        dark: NSColor(red: 62/255, green: 60/255, blue: 68/255, alpha: 1)
    )
    static let focus = Color(
        light: NSColor(red: 110/255, green: 76/255, blue: 135/255, alpha: 1),
        dark: NSColor(red: 190/255, green: 160/255, blue: 225/255, alpha: 1)
    )
    /// Text/glyph accent color: `signalInk`'s light value, but a light lavender in
    /// dark mode (≥4.5:1 on `paper` dark), since `signalInk`'s and `focus`'s dark
    /// values are dark fills unsuitable as foreground text. Use wherever
    /// `signalInk`/`focus`/`orchid` would otherwise be a text or glyph color.
    static let accentForeground = Color(
        light: NSColor(red: 49/255, green: 36/255, blue: 62/255, alpha: 1),
        dark: NSColor(red: 190/255, green: 160/255, blue: 225/255, alpha: 1)
    )
    /// Fixed accent fill (the light-mode `focus` value in both appearances) for
    /// chrome that must stay dark enough for white foreground content regardless
    /// of appearance, such as the listening `DictateButtonStyle` background.
    static let accentFill = Color(
        light: NSColor(red: 110/255, green: 76/255, blue: 135/255, alpha: 1),
        dark: NSColor(red: 110/255, green: 76/255, blue: 135/255, alpha: 1)
    )
    /// Secondary text color for captions, hints, and metadata. Replaces the former
    /// two secondary-text tokens and inline ink-opacity text treatments.
    static let textSecondary = Color(
        light: NSColor(red: 98/255, green: 93/255, blue: 103/255, alpha: 1),
        dark: NSColor(red: 168/255, green: 163/255, blue: 173/255, alpha: 1)
    )
    /// Appearance-aware error text/icon color for inline validation and connection
    /// failures, distinct from the fixed `hudError` used only by the floating HUD.
    static let textError = Color(
        light: NSColor(red: 178/255, green: 58/255, blue: 58/255, alpha: 1),
        dark: NSColor(red: 235/255, green: 120/255, blue: 120/255, alpha: 1)
    )
    /// Appearance-aware success text/icon color for confirmations such as a
    /// verified provider connection.
    static let textSuccess = Color(
        light: NSColor(red: 46/255, green: 125/255, blue: 76/255, alpha: 1),
        dark: NSColor(red: 118/255, green: 200/255, blue: 148/255, alpha: 1)
    )
    /// Fixed near-black surface for chrome that sits above any app or wallpaper
    /// regardless of appearance: the floating HUD capsule.
    static let hudSurface = Color(red: 17/255, green: 16/255, blue: 20/255)

    static let contentWidth: CGFloat = 760

    static let radiusControl: CGFloat = 8
    static let radiusCard: CGFloat = 12
    static let radiusHero: CGFloat = 14

    /// Font for small `Image(systemName:)` glyphs used inside chips, badges, and
    /// custom controls, so no view file reaches for `.font(.system(size:...))` directly.
    static func glyphFont(size: CGFloat, weight: Font.Weight) -> Font { .system(size: size, weight: weight) }

    /// Fixed amber/red feedback colors for the floating HUD's warning and error
    /// states, independent of appearance like `hudSurface`.
    static let hudWarning = Color(red: 245/255, green: 196/255, blue: 81/255)
    static let hudError = Color(red: 1, green: 107/255, blue: 107/255)
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
                        .font(.dictatorBody(weight: .semibold))
                        .foregroundStyle(selection == index ? DictatorDesign.ink : DictatorDesign.textSecondary)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .contentShape(Rectangle())
                        .background(selection == index ? DictatorDesign.control : .clear, in: RoundedRectangle(cornerRadius: DictatorDesign.radiusControl, style: .continuous))
                        .shadow(color: selection == index ? .black.opacity(0.06) : .clear, radius: 2, y: 1)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == index ? .isSelected : [])
            }
        }
        .padding(3)
        .background(DictatorDesign.fog.opacity(0.8), in: RoundedRectangle(cornerRadius: DictatorDesign.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DictatorDesign.radiusCard, style: .continuous).stroke(DictatorDesign.border.opacity(0.7)))
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
            .font(.dictatorBody(weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, kind == .ghost ? 8 : 13)
            .frame(minHeight: 34)
            .background(background(configuration.isPressed), in: RoundedRectangle(cornerRadius: DictatorDesign.radiusControl, style: .continuous))
            .overlay {
                if kind == .secondary {
                    RoundedRectangle(cornerRadius: DictatorDesign.radiusControl, style: .continuous).stroke(DictatorDesign.border, lineWidth: 1)
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

/// Style for the primary Dictate control on Home: solid ink while idle, the
/// focus accent with a soft pulsing ring while listening, and a dimmed
/// (disabled) look while transcribing. The pulsing ring is suppressed under
/// Reduce Motion.
struct DictateButtonStyle: ButtonStyle {
    let phase: DictationPhase

    func makeBody(configuration: Configuration) -> some View {
        DictateButtonChrome(phase: phase, configuration: configuration)
    }
}

private struct DictateButtonChrome: View {
    let phase: DictationPhase
    let configuration: DictateButtonStyle.Configuration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        configuration.label
            .font(.dictatorBodyLarge(weight: .semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 22)
            .frame(height: 52)
            .background(background, in: Capsule())
            .overlay {
                if phase == .listening && !reduceMotion {
                    Capsule()
                        .stroke(DictatorDesign.focus, lineWidth: 2)
                        .scaleEffect(pulsing ? 1.22 : 1)
                        .opacity(pulsing ? 0 : 0.6)
                }
            }
            .opacity(isEnabled ? 1 : 0.6)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 1.1).repeatForever(autoreverses: false), value: pulsing)
            .onAppear { pulsing = phase == .listening && !reduceMotion }
            .onChange(of: phase) { _, newPhase in pulsing = newPhase == .listening && !reduceMotion }
            .onChange(of: reduceMotion) { _, newValue in pulsing = phase == .listening && !newValue }
    }

    private var background: Color {
        switch phase {
        case .idle: DictatorDesign.signalInk
        case .listening: DictatorDesign.accentFill
        case .processing: DictatorDesign.signalInk.opacity(0.7)
        }
    }
}

/// Subtle press feedback for full-width list rows, such as transcript rows:
/// a soft fog background while pressed, no scale or border.
struct PressableRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? DictatorDesign.fog : Color.clear)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct DictatorTextFieldStyle: TextFieldStyle {
    @Environment(\.isFocused) private var isFocused

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(.dictatorBody)
            .padding(.horizontal, 11)
            .frame(height: 36)
            .background(DictatorDesign.control, in: RoundedRectangle(cornerRadius: DictatorDesign.radiusControl, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DictatorDesign.radiusControl, style: .continuous).stroke(isFocused ? DictatorDesign.focus : DictatorDesign.border, lineWidth: isFocused ? 1.5 : 1))
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
                    .font(.dictatorBody)
                    .foregroundStyle(DictatorDesign.ink)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Image(systemName: "chevron.up.chevron.down")
                    .font(DictatorDesign.glyphFont(size: 10, weight: .semibold))
                    .foregroundStyle(DictatorDesign.textSecondary)
            }
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .contentShape(Rectangle())
            .background(DictatorDesign.control, in: RoundedRectangle(cornerRadius: DictatorDesign.radiusControl, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DictatorDesign.radiusControl, style: .continuous).stroke(DictatorDesign.border))
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

struct DictatorCardChrome: ViewModifier {
    var radius: CGFloat = DictatorDesign.radiusCard

    func body(content: Content) -> some View {
        content
            .background(DictatorDesign.control, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(DictatorDesign.border))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct DictatorEmptyState: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(DictatorDesign.glyphFont(size: 12, weight: .semibold)).foregroundStyle(DictatorDesign.accentForeground)
                .frame(width: 30, height: 30).background(DictatorDesign.orchid.opacity(0.38), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.dictatorBody(weight: .semibold))
                Text(detail).font(.dictatorCaption).foregroundStyle(DictatorDesign.textSecondary)
            }
            Spacer()
        }
        .padding(14)
        .modifier(DictatorCardChrome())
        .accessibilityElement(children: .combine)
    }
}

struct FormField<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.dictatorCaption(weight: .semibold)).foregroundStyle(DictatorDesign.textSecondary)
            content
        }
    }
}

struct SectionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title).font(.dictatorBody(weight: .semibold)).foregroundStyle(DictatorDesign.textSecondary)
    }
}

struct DictatorEditorChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .padding(9)
            .background(DictatorDesign.control, in: RoundedRectangle(cornerRadius: DictatorDesign.radiusControl, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DictatorDesign.radiusControl, style: .continuous).stroke(DictatorDesign.border, lineWidth: 1))
    }
}

extension View {
    func dictatorButton(_ kind: DictatorButtonKind = .primary) -> some View { buttonStyle(DictatorButtonStyle(kind: kind)) }
    func dictatorEditor() -> some View { modifier(DictatorEditorChrome()) }
    func dictatorCard(radius: CGFloat = DictatorDesign.radiusCard) -> some View { modifier(DictatorCardChrome(radius: radius)) }
}

extension Font {
    /// Five semantic text styles built on Dynamic Type so "Larger Text" scales the
    /// whole app. Each has a `weight:` variant; the bare `static var` uses the
    /// style's natural weight.
    static func dictatorCaption(weight: Weight = .regular) -> Font { .system(.subheadline, design: .default).weight(weight) }
    static var dictatorCaption: Font { dictatorCaption() }

    static func dictatorBody(weight: Weight = .regular) -> Font { .system(.body, design: .default).weight(weight) }
    static var dictatorBody: Font { dictatorBody() }

    static func dictatorBodyLarge(weight: Weight = .regular) -> Font { .system(.title3, design: .default).weight(weight) }
    static var dictatorBodyLarge: Font { dictatorBodyLarge() }

    static func dictatorTitle(weight: Weight = .semibold) -> Font { .system(.title, design: .default).weight(weight) }
    static var dictatorTitle: Font { dictatorTitle() }

    static func dictatorDisplay(weight: Weight = .semibold) -> Font { .system(.largeTitle, design: .rounded).weight(weight) }
    static var dictatorDisplay: Font { dictatorDisplay() }
}

extension Date {
    var dictatorTimestamp: String {
        let time = formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(self) { return "Today, \(time)" }
        if Calendar.current.isDateInYesterday(self) { return "Yesterday, \(time)" }
        return formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}
