@preconcurrency import CoreGraphics
import Foundation

struct GlobalShortcut: Codable, Equatable, Sendable {
    enum Trigger: Codable, Equatable, Sendable {
        case key(keyCode: Int64, modifiersRawValue: UInt64, label: String)
        case functionModifier
        case modifierChord(modifiersRawValue: UInt64)
        case mouseButton(buttonNumber: Int64)
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

    init?(mouseButtonNumber: Int64) {
        guard Self.supportedMouseButtons.contains(mouseButtonNumber) else { return nil }
        trigger = .mouseButton(buttonNumber: mouseButtonNumber)
    }

    private init(trigger: Trigger) {
        self.trigger = trigger
    }

    var modifiers: CGEventFlags {
        let rawValue = switch trigger {
        case .key(_, let modifiersRawValue, _), .modifierChord(let modifiersRawValue): modifiersRawValue
        case .functionModifier, .mouseButton: UInt64(0)
        }
        return CGEventFlags(rawValue: rawValue).shortcutModifiers
    }

    var displayName: String {
        if case .functionModifier = trigger { return "Fn" }
        if case .mouseButton(let buttonNumber) = trigger {
            return "Mouse Button \(buttonNumber + 1)"
        }
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
            guard Self.isSupported(trigger) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .trigger,
                    in: values,
                    debugDescription: "Mouse button number must be between 2 and 31."
                )
            }
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

    private static let supportedMouseButtons: ClosedRange<Int64> = 2...31

    private static func isSupported(_ trigger: Trigger) -> Bool {
        guard case .mouseButton(let buttonNumber) = trigger else { return true }
        return supportedMouseButtons.contains(buttonNumber)
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
    private var eventTapContext: HotkeyEventTapContext?
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
        eventTapContext?.configure(
            dictate: dictate,
            pasteLatest: pasteLatest,
            openClipboard: openClipboard
        )
    }

    func start() throws {
        guard !isRunning else { return }
        stop()
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.otherMouseUp.rawValue)
        let context = HotkeyEventTapContext(
            dictate: dictateShortcut,
            pasteLatest: pasteShortcut,
            openClipboard: clipboardShortcut
        ) { [weak self] action in
            Task { @MainActor [weak self] in
                self?.dispatch(action)
            }
        }
        let pointer = Unmanaged.passUnretained(context).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: HotkeyEventTapContext.callback,
            userInfo: pointer
        ) else { throw HotkeyError.permissionRequired }
        context.attach(eventTap: tap)
        eventTapContext = context
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
        eventTapContext = nil
    }

    private func dispatch(_ action: HotkeyAction) {
        switch action {
        case .press(let targetPID):
            onPress?(targetPID)
        case .release:
            onRelease?()
        case .screenAwarePress(let targetPID):
            onScreenAwarePress?(targetPID)
        case .screenAwareRelease:
            onScreenAwareRelease?()
        case .pasteLatest:
            onPasteLatest?()
        case .openClipboard:
            onOpenClipboard?()
        }
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

    static func matchesMouseButton(_ shortcut: GlobalShortcut, buttonNumber: Int64) -> Bool {
        guard case .mouseButton(let configuredButtonNumber) = shortcut.trigger else { return false }
        return configuredButtonNumber == buttonNumber
    }
}

enum HotkeyError: LocalizedError {
    case permissionRequired
    var errorDescription: String? { "Input Monitoring permission is required for Dictator shortcuts." }
}
