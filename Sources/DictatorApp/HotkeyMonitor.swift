import CoreGraphics
import Foundation

struct GlobalShortcut: Codable, Equatable, Sendable {
    let keyCode: Int64
    let modifiersRawValue: UInt64
    let keyLabel: String
    let isFunctionModifier: Bool

    init(keyCode: Int64, modifiers: CGEventFlags = [], keyLabel: String, isFunctionModifier: Bool = false) {
        self.keyCode = keyCode
        modifiersRawValue = modifiers.shortcutModifiers.rawValue
        self.keyLabel = keyLabel
        self.isFunctionModifier = isFunctionModifier
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

    static let dictate = GlobalShortcut(keyCode: 63, keyLabel: "Fn", isFunctionModifier: true)
    static let pasteLatest = GlobalShortcut(keyCode: 9, modifiers: [.maskCommand, .maskAlternate], keyLabel: "V")
    static let openClipboard = GlobalShortcut(keyCode: 9, modifiers: [.maskCommand, .maskAlternate, .maskShift], keyLabel: "V")
}

extension CGEventFlags {
    fileprivate var shortcutModifiers: CGEventFlags {
        intersection([.maskCommand, .maskAlternate, .maskShift, .maskControl])
    }
}

protocol HotkeyMonitoring: AnyObject, Sendable {
    var onPress: (@Sendable (pid_t?) -> Void)? { get set }
    var onRelease: (@Sendable () -> Void)? { get set }
    var onPasteLatest: (@Sendable () -> Void)? { get set }
    var onOpenClipboard: (@Sendable () -> Void)? { get set }
    var isRunning: Bool { get }

    func configure(dictate: GlobalShortcut, pasteLatest: GlobalShortcut, openClipboard: GlobalShortcut)
    func start() throws
    func stop()
}

final class HotkeyMonitor: HotkeyMonitoring, @unchecked Sendable {
    var onPress: (@Sendable (pid_t?) -> Void)?
    var onRelease: (@Sendable () -> Void)?
    var onPasteLatest: (@Sendable () -> Void)?
    var onOpenClipboard: (@Sendable () -> Void)?
    private var dictateShortcut = GlobalShortcut.dictate
    private var pasteShortcut = GlobalShortcut.pasteLatest
    private var clipboardShortcut = GlobalShortcut.openClipboard
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var dictateIsDown = false
    var isRunning: Bool {
        guard let eventTap else { return false }
        return CFMachPortIsValid(eventTap) && CGEvent.tapIsEnabled(tap: eventTap)
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
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = monitor.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            if monitor.handle(event, type: type) { return nil }
            return Unmanaged.passUnretained(event)
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
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        runLoopSource = nil
        eventTap = nil
        dictateIsDown = false
    }

    /// Returns true when a Dictator shortcut consumed the event.
    private func handle(_ event: CGEvent, type: CGEventType) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let eventTargetPID = event.getIntegerValueField(.eventTargetUnixProcessID)
        let targetPID = eventTargetPID > 0 ? pid_t(eventTargetPID) : nil

        if dictateShortcut.isFunctionModifier, type == .flagsChanged {
            let down = event.flags.contains(.maskSecondaryFn)
            guard down != dictateIsDown else { return false }
            dictateIsDown = down
            if down { onPress?(targetPID) } else { onRelease?() }
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
        !shortcut.isFunctionModifier && shortcut.keyCode == keyCode && shortcut.modifiers == flags.shortcutModifiers
    }
}

enum HotkeyError: LocalizedError {
    case permissionRequired
    var errorDescription: String? { "Input Monitoring permission is required for Dictator shortcuts." }
}
