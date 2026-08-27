import AppKit
import QuartzCore
import SwiftUI

enum HUDSuccess: Equatable {
    case cancelled
    case copied
    case pasteSent
    case offlineSaved
    case offlineCopied
    case offlinePasteSent

    var label: String {
        switch self {
        case .cancelled: "Cancelled"
        case .copied: "Copied — press ⌘V"
        case .pasteSent: "Paste sent"
        case .offlineSaved: "Offline · Saved"
        case .offlineCopied: "Offline · Copied"
        case .offlinePasteSent: "Offline · Paste sent"
        }
    }

    var panelWidth: CGFloat {
        switch self {
        case .cancelled, .pasteSent: 124
        case .offlineSaved, .offlinePasteSent: 174
        case .copied, .offlineCopied: 196
        }
    }
}

enum HUDPhase: Equatable {
    case idle
    case listening
    case transcribing
    case offline
    case cleaning
    case understanding
    case success(HUDSuccess)
    case clipboard
    case error(String)

    var label: String {
        switch self {
        case .idle: ""
        case .listening: "Listening"
        case .transcribing: "Transcribing"
        case .offline: "Offline mode"
        case .cleaning: "Cleaning up"
        case .understanding: "Understanding screen"
        case .success(let success): success.label
        case .clipboard: "Saved to Dictator clipboard"
        case .error(let value): value
        }
    }
}

enum HUDPositioning {
    private static let topGap: CGFloat = 4

    static func topExclusion(
        screenFrame: NSRect,
        visibleFrame: NSRect,
        topSafeAreaInset: CGFloat
    ) -> CGFloat {
        max(topSafeAreaInset, max(0, screenFrame.maxY - visibleFrame.maxY))
    }

    static func notchFrame(size: NSSize, screenFrame: NSRect, topExclusion: CGFloat) -> NSRect {
        NSRect(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.maxY - topExclusion - topGap - size.height,
            width: size.width,
            height: size.height
        )
    }
}

@MainActor
final class HUDModel: ObservableObject {
    @Published var phase: HUDPhase = .idle
    @Published var levels = Array(repeating: 0.12, count: 22)

    func push(level: Double) {
        levels.removeFirst()
        levels.append(max(0.08, min(1, level)))
    }
}

@MainActor
final class FloatingPanelController {
    let model = HUDModel()
    var onStop: (() -> Void)?
    private let panel: NSPanel
    private var hideTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    private var sessionDisplayID: NSNumber?
    private let transitionDuration = 0.24

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 58),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.panel = panel
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = NSHostingView(rootView: FloatingHUDView(
            model: model,
            onStop: { [weak self] in self?.stopFromPill() }
        ))
        observeScreenChanges()
    }

    isolated deinit {
        hideTask?.cancel()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        panel.close()
    }

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reanchorForScreenChange() }
        }
    }

    /// Panel frames are absolute screen coordinates, so connecting or disconnecting a
    /// display leaves the HUD stranded wherever its old geometry landed.
    private func reanchorForScreenChange() {
        guard panel.isVisible else { return }
        if screen(for: sessionDisplayID) == nil {
            sessionDisplayID = displayID(for: fallbackScreen())
        }
        resize(for: model.phase, animated: false)
    }

    func show(_ phase: HUDPhase) {
        hideTask?.cancel()
        guard phase != .idle else {
            model.phase = .idle
            panel.orderOut(nil)
            return
        }
        if sessionDisplayID == nil {
            sessionDisplayID = displayID(for: fallbackScreen())
        }
        let shouldAnimate = panel.isVisible && model.phase != phase
        let animation: Animation? = shouldAnimate
            ? .spring(response: 0.3, dampingFraction: 1)
            : nil
        withAnimation(animation) { model.phase = phase }
        panel.ignoresMouseEvents = phase != .listening
        resize(for: phase, animated: shouldAnimate)
        panel.orderFrontRegardless()
    }

    func hideAfterDelay() {
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(1.2)) }
            catch { return }
            guard let self else { return }
            let animation = Animation.spring(response: 0.3, dampingFraction: 1)
            withAnimation(animation) { self.model.phase = .idle }
            self.panel.ignoresMouseEvents = true
            self.panel.orderOut(nil)
            self.sessionDisplayID = nil
        }
    }

    func stopFromPill() {
        guard model.phase == .listening else { return }
        onStop?()
    }

    private func resize(for phase: HUDPhase, animated: Bool) {
        let size = size(for: phase)
        guard let target = targetFrame(size: size, phase: phase) else { return }
        guard animated else {
            panel.setFrame(target, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = transitionDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.72, 0.22, 1)
            panel.animator().setFrame(target, display: true)
        }
    }

    private func size(for phase: HUDPhase) -> NSSize {
        switch phase {
        case .idle: NSSize(width: 54, height: 18)
        case .listening:
            NSSize(width: 148, height: 34)
        case .transcribing, .offline, .cleaning, .understanding:
            NSSize(width: 124, height: 32)
        case .success(let success):
            NSSize(width: success.panelWidth, height: 32)
        case .clipboard: NSSize(width: 190, height: 34)
        case .error: NSSize(width: 260, height: 36)
        }
    }

    private func targetFrame(size: NSSize, phase: HUDPhase) -> NSRect? {
        guard let screen = screen(for: sessionDisplayID) ?? fallbackScreen() else { return nil }
        let topExclusion = HUDPositioning.topExclusion(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            topSafeAreaInset: screen.safeAreaInsets.top
        )
        return HUDPositioning.notchFrame(
            size: size,
            screenFrame: screen.frame,
            topExclusion: topExclusion
        )
    }

    private func fallbackScreen() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(pointer) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func displayID(for screen: NSScreen?) -> NSNumber? {
        screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }

    private func screen(for displayID: NSNumber?) -> NSScreen? {
        guard let displayID else { return nil }
        return NSScreen.screens.first { self.displayID(for: $0) == displayID }
    }
}

struct FloatingHUDView: View {
    @ObservedObject var model: HUDModel
    let onStop: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            chrome
            content
                .id(phaseKey)
                .transition(.opacity)
        }
        .padding(0.5)
    }

    @ViewBuilder private var chrome: some View {
        Capsule().fill(Color(red: 17/255, green: 16/255, blue: 20/255).opacity(0.97))
        Capsule().stroke(Color.white.opacity(0.075), lineWidth: 0.75)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle: EmptyView()
        case .listening: listeningState
        case .transcribing, .offline, .cleaning, .understanding: processingState
        default: resultState
        }
    }

    private var listeningState: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(DictatorDesign.orchid.opacity(0.16)).frame(width: 12, height: 12)
                Circle().fill(DictatorDesign.orchid).frame(width: 4, height: 4)
            }
            waveform
            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(DictatorDesign.orchid, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop recording")
        }
        .padding(.horizontal, 8)
        .accessibilityLabel("Listening")
    }

    private var waveform: some View {
        HStack(spacing: 2.2) {
            ForEach(Array(model.levels.suffix(13).enumerated()), id: \.offset) { index, level in
                let shaped = max(0.04, level * (0.78 + sin(Double(index) * 0.9) * 0.16))
                Capsule()
                    .fill(index.isMultiple(of: 4) ? DictatorDesign.orchid : DictatorDesign.orchid.opacity(0.68))
                    .frame(width: 2, height: 2.5 + shaped * 19)
                    .animation(reduceMotion ? nil : .smooth(duration: 0.08), value: level)
            }
        }
        .frame(width: 54, height: 24)
    }

    private var processingState: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let position = reduceMotion ? 2 : Int(timeline.date.timeIntervalSinceReferenceDate * 7) % 4
            HStack(spacing: 8) {
                HStack(spacing: 2.5) {
                    ForEach(0..<4, id: \.self) { index in
                        Circle()
                            .fill(DictatorDesign.orchid.opacity(index == position ? 1 : 0.18 + Double(index) * 0.05))
                            .frame(width: index == position ? 5 : 3, height: index == position ? 5 : 3)
                    }
                }.frame(width: 21)
                Text(model.phase.label)
                    .font(.dictatorBody(11.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }.padding(.horizontal, 9)
        }
        .accessibilityLabel(model.phase.label)
    }

    private var resultState: some View {
        HStack(spacing: 8) {
            Image(systemName: resultIcon).font(.system(size: 10, weight: .bold)).foregroundStyle(resultColor)
            Text(model.phase.label).font(.dictatorBody(12, weight: .semibold)).foregroundStyle(Color.white.opacity(0.92))
                .lineLimit(1)
        }.padding(.horizontal, 13)
        .accessibilityLabel(model.phase.label)
    }

    private var resultIcon: String {
        switch model.phase {
        case .success: "checkmark"
        case .clipboard: "doc.on.clipboard"
        case .error: "exclamationmark"
        default: "checkmark"
        }
    }

    private var resultColor: Color {
        if case .error = model.phase { return .orange }
        return DictatorDesign.orchid
    }

    private var phaseKey: String {
        switch model.phase {
        case .idle: "idle"
        case .listening: "listening"
        case .transcribing: "transcribing"
        case .offline: "offline"
        case .cleaning: "cleaning"
        case .understanding: "understanding"
        case .success: "success"
        case .clipboard: "clipboard"
        case .error: "error"
        }
    }
}
