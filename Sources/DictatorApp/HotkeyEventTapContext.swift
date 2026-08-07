@preconcurrency import CoreGraphics
import Foundation

enum HotkeyAction: Equatable, Sendable {
    case press(pid_t?)
    case release
    case screenAwarePress(pid_t?)
    case screenAwareRelease
    case pasteLatest
    case openClipboard
}

struct HotkeyEventOutcome: Equatable, Sendable {
    let action: HotkeyAction?
    let consumesEvent: Bool

    static let ignored = HotkeyEventOutcome(action: nil, consumesEvent: false)
}

/// Mutable state used only by the event tap attached to the main CFRunLoop.
///
/// CoreGraphics invokes its C callback from that run loop without entering a
/// Swift main-actor executor. Keep this context actor-neutral and forward typed
/// actions across the actor boundary instead of assuming executor isolation.
final class HotkeyEventTapContext {
    private var dictateShortcut: GlobalShortcut
    private var dictateActivation: HotkeyActivationMode
    private var pasteShortcut: GlobalShortcut
    private var clipboardShortcut: GlobalShortcut
    private var dictateIsDown = false
    private var screenAwareIsDown = false
    private var eventTap: CFMachPort?
    private let onAction: @Sendable (HotkeyAction) -> Void

    init(
        dictate: GlobalShortcut,
        dictateActivation: HotkeyActivationMode = .hold,
        pasteLatest: GlobalShortcut,
        openClipboard: GlobalShortcut,
        onAction: @escaping @Sendable (HotkeyAction) -> Void
    ) {
        dictateShortcut = dictate
        self.dictateActivation = dictateActivation
        pasteShortcut = pasteLatest
        clipboardShortcut = openClipboard
        self.onAction = onAction
    }

    func configure(
        dictate: GlobalShortcut,
        dictateActivation: HotkeyActivationMode,
        pasteLatest: GlobalShortcut,
        openClipboard: GlobalShortcut
    ) {
        // A shortcut held across a mode switch can never deliver a matching
        // release under the new mode, so drop the stale held state.
        if dictateActivation != self.dictateActivation { dictateIsDown = false }
        dictateShortcut = dictate
        self.dictateActivation = dictateActivation
        pasteShortcut = pasteLatest
        clipboardShortcut = openClipboard
    }

    func attach(eventTap: CFMachPort) {
        self.eventTap = eventTap
    }

    func process(_ event: CGEvent, type: CGEventType) -> HotkeyEventOutcome {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let eventTargetPID = event.getIntegerValueField(.eventTargetUnixProcessID)
        let targetPID = eventTargetPID > 0 ? pid_t(eventTargetPID) : nil

        if case .functionModifier = dictateShortcut.trigger,
           type == .flagsChanged,
           event.flags.contains(.maskSecondaryFn) || dictateIsDown {
            let down = event.flags.contains(.maskSecondaryFn)
            guard down != dictateIsDown else { return .ignored }
            dictateIsDown = down
            return HotkeyEventOutcome(
                action: down ? .press(targetPID) : releaseAction,
                consumesEvent: false
            )
        }

        if type == .flagsChanged {
            let down = ShortcutMatcher.matchesModifiers(.screenAware, flags: event.flags)
            guard down != screenAwareIsDown else { return .ignored }
            screenAwareIsDown = down
            return HotkeyEventOutcome(
                action: down ? .screenAwarePress(targetPID) : .screenAwareRelease,
                consumesEvent: false
            )
        }

        if case .key(let configuredKeyCode, _, _) = dictateShortcut.trigger,
           keyCode == configuredKeyCode {
            if type == .keyDown,
               ShortcutMatcher.matches(dictateShortcut, keyCode: keyCode, flags: event.flags) {
                guard !dictateIsDown,
                      event.getIntegerValueField(.keyboardEventAutorepeat) == 0
                else {
                    return HotkeyEventOutcome(action: nil, consumesEvent: true)
                }
                dictateIsDown = true
                return HotkeyEventOutcome(action: .press(targetPID), consumesEvent: true)
            }
            if type == .keyUp, dictateIsDown {
                dictateIsDown = false
                return HotkeyEventOutcome(action: releaseAction, consumesEvent: true)
            }
        }

        guard type == .keyDown else { return .ignored }
        if ShortcutMatcher.matches(clipboardShortcut, keyCode: keyCode, flags: event.flags) {
            return HotkeyEventOutcome(action: .openClipboard, consumesEvent: true)
        }
        if ShortcutMatcher.matches(pasteShortcut, keyCode: keyCode, flags: event.flags) {
            return HotkeyEventOutcome(action: .pasteLatest, consumesEvent: true)
        }
        return .ignored
    }

    /// Toggle mode drives both edges from presses, so letting go emits nothing.
    private var releaseAction: HotkeyAction? {
        dictateActivation == .toggle ? nil : .release
    }

    static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let context = Unmanaged<HotkeyEventTapContext>
            .fromOpaque(userInfo)
            .takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            context.reenableTap()
            return Unmanaged.passUnretained(event)
        }

        let outcome = context.process(event, type: type)
        if let action = outcome.action {
            context.onAction(action)
        }
        return outcome.consumesEvent ? nil : Unmanaged.passUnretained(event)
    }

    private func reenableTap() {
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }
}
