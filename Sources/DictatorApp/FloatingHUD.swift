import AppKit
import Observation
import QuartzCore
import SwiftUI

enum HUDSuccess: Equatable {
    case cancelled
    case copied
    case pasteSent
    case copiedViaAppleFallback
    case pasteSentViaAppleFallback

    var label: String {
        switch self {
        case .cancelled: "Cancelled"
        case .copied: "Copied — press ⌘V"
        case .pasteSent: "Paste sent"
        case .copiedViaAppleFallback: "Used Apple On-Device · Copied"
        case .pasteSentViaAppleFallback: "Used Apple On-Device · Paste sent"
        }
    }
}

enum HUDPhase: Equatable {
    case idle
    case listening
    case transcribing
    case cleaning
    case success(HUDSuccess)
    case clipboard(shortcut: String)
    case warning(String)
    case error(String)

    var label: String {
        switch self {
        case .idle: ""
        case .listening: "Listening"
        case .transcribing: "Transcribing"
        case .cleaning: "Cleaning up"
        case .success(let success): success.label
        case .clipboard(let shortcut): "Copied · \(shortcut) to paste"
        case .warning(let value): value
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
@Observable
final class HUDModel {
    var phase: HUDPhase = .idle
    var levels = Array(repeating: 0.12, count: 22)

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
    /// Fixed panel size. Changing an NSPanel frame while the hosted SwiftUI view is
    /// animating triggers AppKit constraint-pass loops, so the panel never resizes;
    /// the capsule inside animates instead.
    static let panelSize = NSSize(width: 380, height: 60)

    init() {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
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
        let hostingView = NSHostingView(rootView: FloatingHUDView(
            model: model,
            onStop: { [weak self] in self?.stopFromPill() }
        ))
        // The panel frame is the source of truth; hosting-view sizing constraints
        // otherwise fight externally set frames and can loop AppKit's constraint pass.
        hostingView.sizingOptions = []
        panel.contentView = hostingView
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
        reposition()
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
        reposition()
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

    private func reposition() {
        guard let target = targetFrame() else { return }
        if panel.frame != target { panel.setFrame(target, display: false) }
    }

    private func targetFrame() -> NSRect? {
        guard let screen = screen(for: sessionDisplayID) ?? fallbackScreen() else { return nil }
        let topExclusion = HUDPositioning.topExclusion(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            topSafeAreaInset: screen.safeAreaInsets.top
        )
        return HUDPositioning.notchFrame(
            size: Self.panelSize,
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
    let model: HUDModel
    let onStop: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var motionAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 1)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            content.fixedSize()
            content.frame(width: 360)
        }
        .id(phaseKey)
        .padding(0.5)
        .background(chrome)
        .transition(.opacity.animation(motionAnimation))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? nil : motionAnimation, value: model.phase)
    }

    @ViewBuilder private var chrome: some View {
        Capsule().fill(DictatorDesign.hudSurface.opacity(0.97))
        Capsule().stroke(Color.white.opacity(0.075), lineWidth: 0.75)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle: EmptyView()
        case .listening: listeningState
        case .transcribing, .cleaning: processingState
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
                    .font(DictatorDesign.glyphFont(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(DictatorDesign.orchid, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Stop recording")
            .accessibilityLabel("Stop recording")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(minHeight: 32)
        .accessibilityLabel("Listening")
    }

    private var waveform: some View {
        HStack(spacing: 2.2) {
            ForEach(Array(model.levels.suffix(13).enumerated()), id: \.offset) { index, level in
                let shaped = max(0.04, level * (0.78 + sin(Double(index) * 0.9) * 0.16))
                Capsule()
                    .fill(index.isMultiple(of: 4) ? DictatorDesign.orchid : DictatorDesign.orchid.opacity(0.68))
                    .frame(width: 2, height: 2.5 + shaped * 19)
                    .animation(reduceMotion ? nil : .smooth(duration: 0.1), value: level)
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
                    .font(.dictatorBody(weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(minHeight: 32)
        }
        .accessibilityLabel(model.phase.label)
    }

    private var resultState: some View {
        HStack(spacing: 8) {
            Image(systemName: resultIcon).font(DictatorDesign.glyphFont(size: 10, weight: .bold)).foregroundStyle(resultColor)
            Text(model.phase.label).font(.dictatorBody(weight: .semibold)).foregroundStyle(Color.white.opacity(0.92))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
        .frame(minHeight: 32)
        .accessibilityLabel(model.phase.label)
    }

    // Internal (not private) so FloatingHUDTests can verify the phase→glyph/color
    // feedback taxonomy directly, without rendering the view hierarchy.
    var resultIcon: String {
        switch model.phase {
        case .success(.cancelled): "xmark"
        case .success(.copiedViaAppleFallback), .success(.pasteSentViaAppleFallback): "exclamationmark.triangle.fill"
        case .success: "checkmark"
        case .clipboard: "doc.on.clipboard"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        default: "checkmark"
        }
    }

    var resultColor: Color {
        switch model.phase {
        case .success(.cancelled): Color.white.opacity(0.7)
        case .success(.copiedViaAppleFallback), .success(.pasteSentViaAppleFallback): DictatorDesign.hudWarning
        case .success: DictatorDesign.orchid
        case .clipboard: Color.white
        case .warning: DictatorDesign.hudWarning
        case .error: DictatorDesign.hudError
        default: DictatorDesign.orchid
        }
    }

    private var phaseKey: String {
        switch model.phase {
        case .idle: "idle"
        case .listening: "listening"
        case .transcribing: "transcribing"
        case .cleaning: "cleaning"
        case .success: "success"
        case .clipboard: "clipboard"
        case .warning: "warning"
        case .error: "error"
        }
    }
}
