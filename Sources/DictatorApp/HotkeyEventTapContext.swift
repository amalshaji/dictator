@preconcurrency import CoreGraphics
import Foundation
import os

enum HotkeyAction: Equatable, Sendable {
    case press(pid_t?)
    case release
    case pasteLatest
}

struct HotkeyEventOutcome: Equatable, Sendable {
    let action: HotkeyAction?
    let consumesEvent: Bool

    static let ignored = HotkeyEventOutcome(action: nil, consumesEvent: false)
}

/// Mutable state used only by the event tap attached to the main CFRunLoop.
///
/// CoreGraphics invokes its C callback from a dedicated background thread with
/// its own CFRunLoop, while `configure(...)` is called from the main actor.
/// All mutable state is protected by a lock so both sides can touch it safely.
final class HotkeyEventTapContext: @unchecked Sendable {
    private struct State {
        var dictateShortcut: GlobalShortcut
        var dictateActivation: HotkeyActivationMode
        var pasteShortcut: GlobalShortcut
        var dictateIsDown = false
        var eventTap: CFMachPort?
    }

    private let state: OSAllocatedUnfairLock<State>
    private let onAction: @Sendable (HotkeyAction) -> Void

    init(
        dictate: GlobalShortcut,
        dictateActivation: HotkeyActivationMode = .hold,
        pasteLatest: GlobalShortcut,
        onAction: @escaping @Sendable (HotkeyAction) -> Void
    ) {
        state = OSAllocatedUnfairLock(initialState: State(
            dictateShortcut: dictate,
            dictateActivation: dictateActivation,
            pasteShortcut: pasteLatest
        ))
        self.onAction = onAction
    }

    func configure(
        dictate: GlobalShortcut,
        dictateActivation: HotkeyActivationMode,
        pasteLatest: GlobalShortcut
    ) {
        state.withLock { state in
            // A shortcut held across a mode switch can never deliver a matching
            // release under the new mode, so drop the stale held state.
            if dictateActivation != state.dictateActivation { state.dictateIsDown = false }
            state.dictateShortcut = dictate
            state.dictateActivation = dictateActivation
            state.pasteShortcut = pasteLatest
        }
    }

    func attach(eventTap: CFMachPort) {
        state.withLock { $0.eventTap = eventTap }
    }

    func process(_ event: CGEvent, type: CGEventType) -> HotkeyEventOutcome {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let eventTargetPID = event.getIntegerValueField(.eventTargetUnixProcessID)
        let targetPID = eventTargetPID > 0 ? pid_t(eventTargetPID) : nil

        return state.withLock { state in
            if case .functionModifier = state.dictateShortcut.trigger,
               type == .flagsChanged,
               event.flags.contains(.maskSecondaryFn) || state.dictateIsDown {
                let down = event.flags.contains(.maskSecondaryFn)
                guard down != state.dictateIsDown else { return .ignored }
                state.dictateIsDown = down
                return HotkeyEventOutcome(
                    action: down ? .press(targetPID) : Self.releaseAction(for: state.dictateActivation),
                    consumesEvent: false
                )
            }

            if case .key(let configuredKeyCode, _, _) = state.dictateShortcut.trigger,
               keyCode == configuredKeyCode {
                if type == .keyDown,
                   ShortcutMatcher.matches(state.dictateShortcut, keyCode: keyCode, flags: event.flags) {
                    guard !state.dictateIsDown,
                          event.getIntegerValueField(.keyboardEventAutorepeat) == 0
                    else {
                        return HotkeyEventOutcome(action: nil, consumesEvent: true)
                    }
                    state.dictateIsDown = true
                    return HotkeyEventOutcome(action: .press(targetPID), consumesEvent: true)
                }
                if type == .keyUp, state.dictateIsDown {
                    state.dictateIsDown = false
                    return HotkeyEventOutcome(
                        action: Self.releaseAction(for: state.dictateActivation),
                        consumesEvent: true
                    )
                }
            }

            guard type == .keyDown else { return .ignored }
            if ShortcutMatcher.matches(state.pasteShortcut, keyCode: keyCode, flags: event.flags) {
                return HotkeyEventOutcome(action: .pasteLatest, consumesEvent: true)
            }
            return .ignored
        }
    }

    /// Toggle mode drives both edges from presses, so letting go emits nothing.
    private static func releaseAction(for activation: HotkeyActivationMode) -> HotkeyAction? {
        activation == .toggle ? nil : .release
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
        let tap = state.withLock { $0.eventTap }
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }
}
