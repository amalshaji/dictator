@preconcurrency import CoreGraphics
import Foundation

struct GlobalShortcut: Codable, Equatable, Sendable {
    enum Trigger: Codable, Equatable, Sendable {
        case key(keyCode: Int64, modifiersRawValue: UInt64, label: String)
        case functionModifier
        case modifierChord(modifiersRawValue: UInt64)
    }

    let trigger: Trigger

    init(
        keyCode: Int64,
        modifiers: CGEventFlags = [],
        keyLabel: String
    ) {
        trigger = .key(
            keyCode: keyCode,
            modifiersRawValue: modifiers.shortcutModifiers.rawValue,
            label: keyLabel
        )
    }

    private init(trigger: Trigger) {
        self.trigger = trigger
    }

    var modifiers: CGEventFlags {
        let rawValue = switch trigger {
        case .key(_, let modifiersRawValue, _), .modifierChord(let modifiersRawValue): modifiersRawValue
        case .functionModifier: UInt64(0)
        }
        return CGEventFlags(rawValue: rawValue).shortcutModifiers
    }

    var displayName: String {
        if case .functionModifier = trigger { return "Fn" }
        var value = ""
        if modifiers.contains(.maskControl) { value += "⌃" }
        if modifiers.contains(.maskAlternate) { value += "⌥" }
        if modifiers.contains(.maskShift) { value += "⇧" }
        if modifiers.contains(.maskCommand) { value += "⌘" }
        if case .key(_, _, let label) = trigger { value += label }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case trigger
        case keyCode, modifiersRawValue, keyLabel, isFunctionModifier, isModifierOnly
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let trigger = try values.decodeIfPresent(Trigger.self, forKey: .trigger) {
            self.trigger = trigger
            return
        }
        let keyCode = try values.decode(Int64.self, forKey: .keyCode)
        let modifiersRawValue = try values.decode(UInt64.self, forKey: .modifiersRawValue)
        let label = try values.decode(String.self, forKey: .keyLabel)
        if try values.decodeIfPresent(Bool.self, forKey: .isFunctionModifier) == true {
            trigger = .functionModifier
        } else if try values.decodeIfPresent(Bool.self, forKey: .isModifierOnly) == true {
            trigger = .modifierChord(modifiersRawValue: modifiersRawValue)
        } else {
            trigger = .key(keyCode: keyCode, modifiersRawValue: modifiersRawValue, label: label)
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(trigger, forKey: .trigger)
    }

    private static let screenAwareModifiers: CGEventFlags = [.maskControl, .maskAlternate]
    static let dictate = GlobalShortcut(trigger: .functionModifier)
    static let screenAware = GlobalShortcut(trigger: .modifierChord(
        modifiersRawValue: screenAwareModifiers.rawValue
    ))
    static let pasteLatest = GlobalShortcut(keyCode: 9, modifiers: [.maskCommand, .maskAlternate], keyLabel: "V")
    static let openClipboard = GlobalShortcut(keyCode: 9, modifiers: [.maskCommand, .maskAlternate, .maskShift], keyLabel: "V")
}

extension CGEventFlags {
    fileprivate var shortcutModifiers: CGEventFlags {
        intersection([.maskCommand, .maskAlternate, .maskShift, .maskControl])
    }
}

@MainActor
protocol HotkeyMonitoring: AnyObject {
    var onPress: ((pid_t?) -> Void)? { get set }
    var onRelease: (() -> Void)? { get set }
    var onScreenAwarePress: ((pid_t?) -> Void)? { get set }
    var onScreenAwareRelease: (() -> Void)? { get set }
    var onPasteLatest: (() -> Void)? { get set }
    var onOpenClipboard: (() -> Void)? { get set }
    var isRunning: Bool { get }

    func configure(dictate: GlobalShortcut, pasteLatest: GlobalShortcut, openClipboard: GlobalShortcut)
    func start() throws
    func stop()
}

@MainActor
final class HotkeyMonitor: HotkeyMonitoring {
    var onPress: ((pid_t?) -> Void)?
    var onRelease: (() -> Void)?
    var onScreenAwarePress: ((pid_t?) -> Void)?
    var onScreenAwareRelease: (() -> Void)?
    var onPasteLatest: (() -> Void)?
    var onOpenClipboard: (() -> Void)?
    private var dictateShortcut = GlobalShortcut.dictate
    private var pasteShortcut = GlobalShortcut.pasteLatest
    private var clipboardShortcut = GlobalShortcut.openClipboard
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var dictateIsDown = false
    private var screenAwareIsDown = false
    var isRunning: Bool {
        guard let eventTap else { return false }
        return Self.isTapHealthy(
            isValid: CFMachPortIsValid(eventTap),
            isEnabled: CGEvent.tapIsEnabled(tap: eventTap)
        )
    }

    static func isTapHealthy(isValid: Bool, isEnabled: Bool) -> Bool {
        isValid && isEnabled
    }

    func configure(dictate: GlobalShortcut, pasteLatest: GlobalShortcut, openClipboard: GlobalShortcut) {
        dictateShortcut = dictate
        pasteShortcut = pasteLatest
        clipboardShortcut = openClipboard
    }

    func start() throws {
        guard !isRunning else { return }
        stop()
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            return MainActor.assumeIsolated {
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = monitor.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                if monitor.handle(event, type: type) { return nil }
                return Unmanaged.passUnretained(event)
            }
        }
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: pointer
        ) else { throw HotkeyError.permissionRequired }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        runLoopSource = nil
        eventTap = nil
        dictateIsDown = false
        screenAwareIsDown = false
    }

    /// Returns true when a Dictator shortcut consumed the event.
    func handle(_ event: CGEvent, type: CGEventType) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let eventTargetPID = event.getIntegerValueField(.eventTargetUnixProcessID)
        let targetPID = eventTargetPID > 0 ? pid_t(eventTargetPID) : nil

        if case .functionModifier = dictateShortcut.trigger,
           type == .flagsChanged,
           event.flags.contains(.maskSecondaryFn) || dictateIsDown {
            let down = event.flags.contains(.maskSecondaryFn)
            guard down != dictateIsDown else { return false }
            dictateIsDown = down
            if down { onPress?(targetPID) } else { onRelease?() }
            return false
        }

        if type == .flagsChanged {
            let down = ShortcutMatcher.matchesModifiers(.screenAware, flags: event.flags)
            guard down != screenAwareIsDown else { return false }
            screenAwareIsDown = down
            if down { onScreenAwarePress?(targetPID) } else { onScreenAwareRelease?() }
            return false
        }

        if case .key(let configuredKeyCode, _, _) = dictateShortcut.trigger,
           keyCode == configuredKeyCode {
            if type == .keyDown, ShortcutMatcher.matches(dictateShortcut, keyCode: keyCode, flags: event.flags) {
                guard !dictateIsDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return true }
                dictateIsDown = true
                onPress?(targetPID)
                return true
            }
            if type == .keyUp, dictateIsDown {
                dictateIsDown = false
                onRelease?()
                return true
            }
        }

        guard type == .keyDown else { return false }
        if ShortcutMatcher.matches(clipboardShortcut, keyCode: keyCode, flags: event.flags) {
            onOpenClipboard?()
            return true
        }
        if ShortcutMatcher.matches(pasteShortcut, keyCode: keyCode, flags: event.flags) {
            onPasteLatest?()
            return true
        }
        return false
    }
}

enum ShortcutMatcher {
    static func matches(_ shortcut: GlobalShortcut, keyCode: Int64, flags: CGEventFlags) -> Bool {
        guard case .key(let configuredKeyCode, let modifiersRawValue, _) = shortcut.trigger else {
            return false
        }
        return configuredKeyCode == keyCode
            && CGEventFlags(rawValue: modifiersRawValue).shortcutModifiers == flags.shortcutModifiers
    }

    static func matchesModifiers(_ shortcut: GlobalShortcut, flags: CGEventFlags) -> Bool {
        guard case .modifierChord(let modifiersRawValue) = shortcut.trigger else { return false }
        return CGEventFlags(rawValue: modifiersRawValue).shortcutModifiers == flags.shortcutModifiers
    }
}

enum HotkeyError: LocalizedError {
    case permissionRequired
    var errorDescription: String? { "Input Monitoring permission is required for Dictator shortcuts." }
}
