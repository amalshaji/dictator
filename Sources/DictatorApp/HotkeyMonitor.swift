@preconcurrency import CoreGraphics
import Foundation

/// How the dictate shortcut starts and stops a recording.
enum HotkeyActivationMode: String, CaseIterable, Identifiable, Sendable {
    /// Record while the shortcut is held; stop on release.
    case hold
    /// Start on the first press, stop on the next press.
    case toggle

    var id: String { rawValue }
}

struct GlobalShortcut: Codable, Equatable, Sendable {
    enum Trigger: Codable, Equatable, Sendable {
        case key(keyCode: Int64, modifiersRawValue: UInt64, label: String)
        case functionModifier
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
        case .key(_, let modifiersRawValue, _): modifiersRawValue
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
        case keyCode, modifiersRawValue, keyLabel, isFunctionModifier
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
        } else {
            trigger = .key(keyCode: keyCode, modifiersRawValue: modifiersRawValue, label: label)
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(trigger, forKey: .trigger)
    }

    static let dictate = GlobalShortcut(trigger: .functionModifier)
    static let pasteLatest = GlobalShortcut(keyCode: 9, modifiers: [.maskCommand, .maskAlternate], keyLabel: "V")
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
    var onPasteLatest: (() -> Void)? { get set }
    var isRunning: Bool { get }

    func configure(
        dictate: GlobalShortcut,
        dictateActivation: HotkeyActivationMode,
        pasteLatest: GlobalShortcut
    )
    func start() throws
    func stop()
}

/// Bridges the result of creating the event tap out of its dedicated thread.
/// Mutated only before `setupComplete` is signaled and read only after it is
/// waited on, so the semaphore hand-off is the sole synchronization needed.
private final class TapCreationResult: @unchecked Sendable {
    var tap: CFMachPort?
    var runLoop: CFRunLoop?
}

@MainActor
final class HotkeyMonitor: HotkeyMonitoring {
    var onPress: ((pid_t?) -> Void)?
    var onRelease: (() -> Void)?
    var onPasteLatest: (() -> Void)?
    private var dictateShortcut = GlobalShortcut.dictate
    private var dictateActivation = HotkeyActivationMode.hold
    private var pasteShortcut = GlobalShortcut.pasteLatest
    private var eventTap: CFMachPort?
    private var eventTapThread: Thread?
    private var tapRunLoop: CFRunLoop?
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

    func configure(
        dictate: GlobalShortcut,
        dictateActivation: HotkeyActivationMode,
        pasteLatest: GlobalShortcut
    ) {
        dictateShortcut = dictate
        self.dictateActivation = dictateActivation
        pasteShortcut = pasteLatest
        eventTapContext?.configure(
            dictate: dictate,
            dictateActivation: dictateActivation,
            pasteLatest: pasteLatest
        )
    }

    func start() throws {
        guard !isRunning else { return }
        stop()
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let context = HotkeyEventTapContext(
            dictate: dictateShortcut,
            dictateActivation: dictateActivation,
            pasteLatest: pasteShortcut
        ) { [weak self] action in
            Task { @MainActor [weak self] in
                self?.dispatch(action)
            }
        }

        // The tap's run loop source runs on its own thread instead of the
        // main one, so a main-actor stall (e.g. the Accessibility capture
        // walk, a cleanup network call) never delays keyboard event delivery
        // system-wide. `start()` still waits for setup to finish so it can
        // keep throwing `HotkeyError.permissionRequired` synchronously.
        let result = TapCreationResult()
        let setupComplete = DispatchSemaphore(value: 0)
        let thread = Thread {
            let pointer = Unmanaged.passUnretained(context).toOpaque()
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: HotkeyEventTapContext.callback,
                userInfo: pointer
            ) else {
                setupComplete.signal()
                return
            }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            let runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            result.tap = tap
            result.runLoop = runLoop
            setupComplete.signal()
            // The C callback only holds an unretained reference to `context`
            // via `pointer`, so keep it alive for as long as this thread's
            // run loop may still be invoking it, even if `stop()` drops
            // `eventTapContext` on the main thread while a callback is
            // in flight here.
            withExtendedLifetime(context) { CFRunLoopRun() }
        }
        thread.name = "ai.dictator.hotkey-event-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        setupComplete.wait()

        guard let tap = result.tap, let runLoop = result.runLoop else {
            throw HotkeyError.permissionRequired
        }
        context.attach(eventTap: tap)
        eventTapContext = context
        eventTap = tap
        eventTapThread = thread
        tapRunLoop = runLoop
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let tapRunLoop { CFRunLoopStop(tapRunLoop) }
        eventTap = nil
        eventTapThread = nil
        tapRunLoop = nil
        eventTapContext = nil
    }

    private func dispatch(_ action: HotkeyAction) {
        switch action {
        case .press(let targetPID):
            onPress?(targetPID)
        case .release:
            onRelease?()
        case .pasteLatest:
            onPasteLatest?()
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
}

enum HotkeyError: LocalizedError {
    case permissionRequired
    var errorDescription: String? { "Input Monitoring permission is required for Dictator shortcuts." }
}
