@preconcurrency import CoreGraphics
import Foundation

struct GlobalShortcut: Codable, Equatable, Sendable {
    let keyCode: Int64
    let modifiersRawValue: UInt64
    let keyLabel: String
    let isFunctionModifier: Bool
    let isModifierOnly: Bool

    init(
        keyCode: Int64,
        modifiers: CGEventFlags = [],
        keyLabel: String,
        isFunctionModifier: Bool = false,
        isModifierOnly: Bool = false
    ) {
        self.keyCode = keyCode
        modifiersRawValue = modifiers.shortcutModifiers.rawValue
        self.keyLabel = keyLabel
        self.isFunctionModifier = isFunctionModifier
        self.isModifierOnly = isModifierOnly
    }

    var modifiers: CGEventFlags { CGEventFlags(rawValue: modifiersRawValue).shortcutModifiers }
    var displayName: String {
        if isFunctionModifier { return "Fn" }
        var value = ""
        if modifiers.contains(.maskControl) { value += "⌃" }
        if modifiers.contains(.maskAlternate) { value += "⌥" }
        if modifiers.contains(.maskShift) { value += "⇧" }
        if modifiers.contains(.maskCommand) { value += "⌘" }
        return value + keyLabel
    }

    private enum CodingKeys: String, CodingKey {
        case keyCode, modifiersRawValue, keyLabel, isFunctionModifier, isModifierOnly
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try values.decode(Int64.self, forKey: .keyCode)
        modifiersRawValue = try values.decode(UInt64.self, forKey: .modifiersRawValue)
        keyLabel = try values.decode(String.self, forKey: .keyLabel)
        isFunctionModifier = try values.decodeIfPresent(Bool.self, forKey: .isFunctionModifier) ?? false
        isModifierOnly = try values.decodeIfPresent(Bool.self, forKey: .isModifierOnly) ?? false
    }

    static let dictate = GlobalShortcut(keyCode: 63, keyLabel: "Fn", isFunctionModifier: true)
    static let screenAware = GlobalShortcut(
        keyCode: -1,
        modifiers: [.maskControl, .maskAlternate],
        keyLabel: "",
        isModifierOnly: true
    )
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

    func configure(dictate: GlobalShortcut, screenAware: GlobalShortcut, pasteLatest: GlobalShortcut, openClipboard: GlobalShortcut)
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
    private var screenAwareShortcut = GlobalShortcut.screenAware
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

    func configure(dictate: GlobalShortcut, screenAware: GlobalShortcut, pasteLatest: GlobalShortcut, openClipboard: GlobalShortcut) {
        dictateShortcut = dictate
        screenAwareShortcut = screenAware
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

        if dictateShortcut.isFunctionModifier,
           type == .flagsChanged,
           event.flags.contains(.maskSecondaryFn) || dictateIsDown {
            let down = event.flags.contains(.maskSecondaryFn)
            guard down != dictateIsDown else { return false }
            dictateIsDown = down
            if down { onPress?(targetPID) } else { onRelease?() }
            return false
        }

        if screenAwareShortcut.isModifierOnly, type == .flagsChanged {
            let down = ShortcutMatcher.matchesModifiers(screenAwareShortcut, flags: event.flags)
            guard down != screenAwareIsDown else { return false }
            screenAwareIsDown = down
            if down { onScreenAwarePress?(targetPID) } else { onScreenAwareRelease?() }
            return false
        }

        if !dictateShortcut.isFunctionModifier, keyCode == dictateShortcut.keyCode {
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
        !shortcut.isFunctionModifier && !shortcut.isModifierOnly
            && shortcut.keyCode == keyCode && shortcut.modifiers == flags.shortcutModifiers
    }

    static func matchesModifiers(_ shortcut: GlobalShortcut, flags: CGEventFlags) -> Bool {
        shortcut.isModifierOnly && shortcut.modifiers == flags.shortcutModifiers
    }
}

enum HotkeyError: LocalizedError {
    case permissionRequired
    var errorDescription: String? { "Input Monitoring permission is required for Dictator shortcuts." }
}
