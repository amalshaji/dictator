import AppKit
import CoreGraphics
import SwiftUI

struct ShortcutRecorder: View {
    final class EventMonitors {
        typealias EventHandler = (NSEvent) -> NSEvent?
        typealias AddLocal = (NSEvent.EventTypeMask, @escaping EventHandler) -> Any?
        typealias AddGlobal = (NSEvent.EventTypeMask, @escaping (NSEvent) -> Void) -> Any?
        typealias Remove = (Any) -> Void

        private let addLocal: AddLocal
        private let addGlobal: AddGlobal
        private let remove: Remove
        private var localMonitor: Any?
        private var globalMonitor: Any?

        init(
            addLocal: @escaping AddLocal = { mask, handler in
                NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler)
            },
            addGlobal: @escaping AddGlobal = { mask, handler in
                NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler)
            },
            remove: @escaping Remove = { NSEvent.removeMonitor($0) }
        ) {
            self.addLocal = addLocal
            self.addGlobal = addGlobal
            self.remove = remove
        }

        func start(handler: @escaping EventHandler) {
            stop()
            let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged]
            // Each monitor excludes the other's event scope, so recording needs both.
            localMonitor = addLocal(mask, handler)
            globalMonitor = addGlobal(mask) { event in _ = handler(event) }
        }

        func stop() {
            if let localMonitor { remove(localMonitor) }
            if let globalMonitor { remove(globalMonitor) }
            localMonitor = nil
            globalMonitor = nil
        }
    }

    let shortcut: GlobalShortcut
    var allowsFunctionModifier = false
    let onChange: (GlobalShortcut) -> Bool

    @State private var isRecording = false
    @State private var eventMonitors = EventMonitors()
    @State private var hint: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button(isRecording ? "Type shortcut…" : shortcut.displayName) {
                isRecording ? stopRecording() : startRecording()
            }
            .dictatorButton(isRecording ? .primary : .secondary)
            .frame(minWidth: 112, alignment: .trailing)
            .accessibilityLabel(isRecording ? "Waiting for shortcut" : "Change shortcut, currently \(shortcut.displayName)")

            if let hint {
                Text(hint).font(.dictatorUtility(9)).foregroundStyle(.orange)
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        stopRecording()
        hint = "Press Esc to cancel"
        isRecording = true
        eventMonitors.start { event in handle(event) }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        if event.type == .flagsChanged {
            if allowsFunctionModifier, event.keyCode == 63, event.modifierFlags.contains(.function) {
                accept(.dictate)
                return nil
            }
            return event
        }

        if event.keyCode == 53 {
            stopRecording()
            return nil
        }

        let modifiers = cgModifiers(from: event.modifierFlags)
        guard !modifiers.isEmpty || isFunctionKey(event.keyCode) else {
            hint = "Add a modifier, or use an F-key"
            return nil
        }
        let captured = GlobalShortcut(
            keyCode: Int64(event.keyCode),
            modifiers: modifiers,
            keyLabel: keyLabel(for: event)
        )
        accept(captured)
        return nil
    }

    private func accept(_ captured: GlobalShortcut) {
        if onChange(captured) {
            stopRecording()
        } else {
            hint = "That shortcut is already in use"
        }
    }

    private func stopRecording() {
        eventMonitors.stop()
        isRecording = false
        hint = nil
    }

    private func cgModifiers(from flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var result: CGEventFlags = []
        if flags.contains(.control) { result.insert(.maskControl) }
        if flags.contains(.option) { result.insert(.maskAlternate) }
        if flags.contains(.shift) { result.insert(.maskShift) }
        if flags.contains(.command) { result.insert(.maskCommand) }
        return result
    }

    private func isFunctionKey(_ keyCode: UInt16) -> Bool {
        keyLabelByCode[keyCode]?.hasPrefix("F") == true
    }

    private func keyLabel(for event: NSEvent) -> String {
        if let known = keyLabelByCode[event.keyCode] { return known }
        let characters = event.charactersIgnoringModifiers?.uppercased() ?? ""
        return characters.isEmpty ? "Key \(event.keyCode)" : characters
    }

    private var keyLabelByCode: [UInt16: String] {
        [
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "Esc",
            115: "Home", 116: "Page Up", 117: "⌦", 119: "End", 121: "Page Down",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18",
            80: "F19", 90: "F20"
        ]
    }
}
