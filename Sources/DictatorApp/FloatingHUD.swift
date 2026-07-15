import AppKit
import QuartzCore
import SwiftUI

enum HUDPositionMode: String, CaseIterable, Identifiable {
    case bottom
    case pointer

    var id: String { rawValue }
}

enum HUDPhase: Equatable {
    case idle
    case listening
    case transcribing
    case offline
    case cleaning
    case success(String)
    case clipboard
    case error(String)

    var label: String {
        switch self {
        case .idle: ""
        case .listening: "Listening"
        case .transcribing: "Transcribing"
        case .offline: "Offline mode"
        case .cleaning: "Cleaning up"
        case .success(let value): value
        case .clipboard: "Saved to Dictator clipboard"
        case .error(let value): value
        }
    }

    var tracksPointer: Bool {
        self != .idle
    }
}

enum HUDPositioning {
    private static let pointerGap: CGFloat = 16
    private static let screenInset: CGFloat = 8

    static func pointerFrame(size: NSSize, pointer: NSPoint, visibleFrame: NSRect) -> NSRect {
        let bounds = visibleFrame.insetBy(dx: screenInset, dy: screenInset)
        let constrainedSize = NSSize(
            width: min(size.width, max(0, bounds.width)),
            height: min(size.height, max(0, bounds.height))
        )

        var x = pointer.x + pointerGap
        if x + constrainedSize.width > bounds.maxX {
            x = pointer.x - pointerGap - constrainedSize.width
        }

        var y = pointer.y + pointerGap
        if y + constrainedSize.height > bounds.maxY {
            y = pointer.y - pointerGap - constrainedSize.height
        }

        x = min(max(x, bounds.minX), max(bounds.minX, bounds.maxX - constrainedSize.width))
        y = min(max(y, bounds.minY), max(bounds.minY, bounds.maxY - constrainedSize.height))
        return NSRect(origin: NSPoint(x: x, y: y), size: constrainedSize)
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
    private let panel: NSPanel
    private var hideTask: Task<Void, Never>?
    private var pointerTrackingTask: Task<Void, Never>?
    private var positionMode: HUDPositionMode = .bottom
    private var lastPointerLocation: NSPoint?
    private let transitionDuration = 0.24

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 58),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: FloatingHUDView(model: model))
    }

    func setPositionMode(_ mode: HUDPositionMode) {
        guard positionMode != mode else { return }
        positionMode = mode
        resize(for: model.phase, animated: panel.isVisible)
        updatePointerTracking(for: model.phase)
    }

    func show(_ phase: HUDPhase) {
        hideTask?.cancel()
        let shouldAnimate = panel.isVisible && model.phase != phase
        let animation = Animation.timingCurve(0.22, 0.72, 0.22, 1, duration: shouldAnimate ? transitionDuration : 0)
        withAnimation(animation) { model.phase = phase }
        resize(for: phase, animated: shouldAnimate)
        updatePointerTracking(for: phase)
        panel.orderFrontRegardless()
    }

    func hideAfterDelay() {
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(1.2)) }
            catch { return }
            guard let self else { return }
            let animation = Animation.timingCurve(0.22, 0.72, 0.22, 1, duration: self.transitionDuration)
            withAnimation(animation) { self.model.phase = .idle }
            self.updatePointerTracking(for: .idle)
            self.resize(for: .idle, animated: true)
        }
    }

    private func resize(for phase: HUDPhase, animated: Bool) {
        let size = size(for: phase)
        guard let target = targetFrame(size: size, phase: phase) else { return }
        guard animated, positionMode == .bottom else {
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
        case .listening, .transcribing, .offline, .cleaning:
            NSSize(width: 124, height: 32)
        case .success(let message):
            NSSize(width: message.hasPrefix("Offline") ? 174 : 124, height: 32)
        case .clipboard: NSSize(width: 190, height: 34)
        case .error: NSSize(width: 260, height: 36)
        }
    }

    private func targetFrame(size: NSSize, phase: HUDPhase) -> NSRect? {
        if positionMode == .pointer, phase.tracksPointer {
            let pointer = NSEvent.mouseLocation
            guard let screen = screen(containing: pointer) else { return nil }
            return HUDPositioning.pointerFrame(size: size, pointer: pointer, visibleFrame: screen.visibleFrame)
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        let frame = screen.visibleFrame
        return NSRect(
            x: frame.midX - size.width / 2,
            y: frame.minY + 31 - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func updatePointerTracking(for phase: HUDPhase) {
        guard positionMode == .pointer, phase.tracksPointer else {
            pointerTrackingTask?.cancel()
            pointerTrackingTask = nil
            lastPointerLocation = nil
            return
        }
        guard pointerTrackingTask == nil else { return }
        lastPointerLocation = nil
        pointerTrackingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.updatePointerPosition()
                do { try await Task.sleep(for: .milliseconds(16)) }
                catch { return }
            }
        }
    }

    private func updatePointerPosition() {
        let pointer = NSEvent.mouseLocation
        guard pointer != lastPointerLocation else { return }
        lastPointerLocation = pointer
        guard let screen = screen(containing: pointer) else { return }
        let target = HUDPositioning.pointerFrame(
            size: size(for: model.phase),
            pointer: pointer,
            visibleFrame: screen.visibleFrame
        )
        if panel.frame.size == target.size {
            panel.setFrameOrigin(target.origin)
        } else {
            panel.setFrame(target, display: true)
        }
    }

    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens.first
    }
}

struct FloatingHUDView: View {
    @ObservedObject var model: HUDModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Capsule().fill(Color(red: 17/255, green: 16/255, blue: 20/255).opacity(0.97))
            Capsule().stroke(Color.white.opacity(0.075), lineWidth: 0.75)
            content
                .id(phaseKey)
                .transition(.opacity)
        }
        .padding(0.5)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle: EmptyView()
        case .listening: listeningState
        case .transcribing, .offline, .cleaning: processingState
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
        case .success: "success"
        case .clipboard: "clipboard"
        case .error: "error"
        }
    }
}
