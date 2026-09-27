import DictatorCore
import SwiftUI

enum Destination: String, CaseIterable, Identifiable {
    case home = "Home"
    case pipeline = "Pipeline"
    case library = "Library"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .home: "waveform.path"
        case .pipeline: "arrow.triangle.branch"
        case .library: "text.book.closed"
        case .settings: "gearshape"
        }
    }

    /// The number in the ⌘-number shortcut that selects this destination from the
    /// app's commands, in the same order as `allCases`.
    var keyboardNumber: Int {
        switch self {
        case .home: 1
        case .pipeline: 2
        case .library: 3
        case .settings: 4
        }
    }
}

/// Shared navigation selection so the app's `.commands` menu can switch the
/// window's sidebar selection without threading a binding through the scene.
@Observable
final class NavigationModel {
    var destination: Destination? = .home
}

struct MainView: View {
    let model: AppModel
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        @Bindable var navigation = navigation
        NavigationSplitView {
            sidebar(selection: $navigation.destination)
        } detail: {
            content(for: navigation.destination ?? .home)
                .background(DictatorDesign.paper)
                // A non-empty title keeps the Window menu entry from being blank.
                // `.toolbar(removing: .title)` would hide the resulting toolbar
                // title, but that API needs macOS 15; on this macOS 14 deployment
                // target the sidebar wordmark drops its text instead, so the title
                // only appears once (in the toolbar).
                .navigationTitle("Dictator")
                .toolbarTitleDisplayMode(.inline)
        }
        .overlay {
            if !model.onboardingComplete {
                OnboardingView(model: model)
                    .transition(.opacity)
            }
        }
    }

    private func sidebar(selection: Binding<Destination?>) -> some View {
        List(selection: selection) {
            ForEach(Destination.allCases) { item in
                Label(item.rawValue, systemImage: item.icon)
                    .tag(item)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        .safeAreaInset(edge: .top) { wordmark }
        .safeAreaInset(edge: .bottom) { statusBlock }
    }

    // Just the glyph: the window toolbar now carries the "Dictator" title text
    // (see `.navigationTitle` above), so repeating it here would show it twice.
    private var wordmark: some View {
        HStack(spacing: 9) {
            WaveMark()
        }
        .accessibilityLabel("Dictator")
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// Reduced to a single caption line: the Home header already restates access
    /// mode and shortcut instructions in full, so this only needs to surface the
    /// live listening/transcribing state or, at rest, a short reminder.
    private var statusBlock: some View {
        Group {
            switch model.phase {
            case .listening: statusRow("Listening…")
            case .processing: statusRow("Transcribing…")
            case .idle:
                Text(idleCaption)
                    .font(.dictatorCaption).foregroundStyle(DictatorDesign.textSecondary)
            }
        }
        .padding(12)
    }

    private var idleCaption: String {
        if model.accessMode == .leastPrivileges { return "Record from the menu bar" }
        if !model.shortcutsAvailable { return "Shortcuts need permission" }
        return model.dictateInstruction
    }

    private func statusRow(_ text: String) -> some View {
        HStack(spacing: 7) {
            Circle().fill(DictatorDesign.orchid).frame(width: 6, height: 6)
            Text(text).font(.dictatorCaption(weight: .medium)).foregroundStyle(DictatorDesign.ink)
        }
    }

    @ViewBuilder
    private func content(for destination: Destination) -> some View {
        switch destination {
        case .home: HomeView(model: model)
        case .pipeline: PipelineView(model: model)
        case .library: LibraryView(model: model)
        case .settings: SettingsView(model: model)
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
