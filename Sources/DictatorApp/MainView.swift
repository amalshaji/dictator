import AppKit
import DictatorCore
import SwiftUI

enum Destination: String, CaseIterable, Identifiable {
    case home = "Home"
    case providers = "Providers"
    case vocabulary = "Vocabulary"
    case rules = "Styles & snippets"
    case clipboard = "Clipboard"
    case settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: "waveform.path"
        case .providers: "point.3.connected.trianglepath.dotted"
        case .vocabulary: "text.book.closed"
        case .rules: "wand.and.stars"
        case .clipboard: "doc.on.clipboard"
        case .settings: "slider.horizontal.3"
        }
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var destination: Destination = .home

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(DictatorDesign.fog).frame(width: 1)
            content
        }
        .background(DictatorDesign.paper)
        .background(WindowChromeConfigurator())
        .ignoresSafeArea(.container, edges: [.top, .leading])
        .preferredColorScheme(.light)
        .overlay {
            if !model.onboardingComplete {
                OnboardingView(model: model)
                    .transition(.opacity)
            }
        }
        .onChange(of: model.requestedDestination) { _, value in
            guard let value, let requested = Destination(rawValue: value) else { return }
            destination = requested
            model.requestedDestination = nil
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                WaveMark()
                Text("Dictator").font(.dictatorDisplay(18)).foregroundStyle(.white)
            }
            .padding(.horizontal, 20)
            .padding(.top, 54)
            .padding(.bottom, 26)

            ForEach(Destination.allCases) { item in
                SidebarItemButton(item: item, isSelected: destination == item) {
                    destination = item
                }
            }

            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Circle().fill(model.shortcutsAvailable ? Color.green : Color.orange).frame(width: 6, height: 6)
                    Text(model.shortcutsAvailable ? "Ready" : "Shortcuts need permission")
                }
                HStack(spacing: 7) {
                    Text(model.dictateShortcut.displayName)
                        .font(.dictatorUtility(9)).foregroundStyle(.white.opacity(0.78))
                        .padding(.horizontal, 7).frame(height: 22)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text("Hold to speak").font(.dictatorBody(10.5)).foregroundStyle(.white.opacity(0.46))
                }
            }
            .font(.dictatorBody(11, weight: .medium))
            .foregroundStyle(.white.opacity(0.72))
            .padding(12)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(10)
        }
        .frame(width: DictatorDesign.sidebarWidth)
        .background(DictatorDesign.ink)
    }

    @ViewBuilder private var content: some View {
        switch destination {
        case .home: HomeView(model: model)
        case .providers: ProvidersView(model: model)
        case .vocabulary: VocabularyView(model: model)
        case .rules: StylesSnippetsView(model: model)
        case .clipboard: ClipboardView(model: model)
        case .settings: SettingsView(model: model)
        }
    }
}

private struct SidebarItemButton: View {
    let item: Destination
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { action() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .font(.system(size: 11.5, weight: .medium))
                    .frame(width: 24, height: 24)
                    .foregroundStyle(isSelected ? DictatorDesign.signalInk : Color.white.opacity(0.58))
                    .background(isSelected ? DictatorDesign.orchid : Color.white.opacity(isHovered ? 0.07 : 0.035), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(item.rawValue)
                    .font(.dictatorBody(12.5, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Color.white : Color.white.opacity(isHovered ? 0.86 : 0.65))
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.105) : Color.white.opacity(isHovered ? 0.045 : 0))
                    .padding(.horizontal, 10)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .accessibilityLabel(item.rawValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        apply(to: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.backgroundColor = NSColor(red: 23 / 255, green: 21 / 255, blue: 26 / 255, alpha: 1)
        }
    }
}

private struct WaveMark: View {
    var body: some View {
        HStack(spacing: 2) {
            ForEach([7.0, 13, 19, 11, 6], id: \.self) { height in
                Capsule().fill(DictatorDesign.orchid).frame(width: 3, height: height)
            }
        }
        .frame(width: 26, height: 24)
    }
}
