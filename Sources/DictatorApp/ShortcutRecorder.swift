import AppKit
import CoreGraphics
import SwiftUI

struct ShortcutRecorder: View {
    let shortcut: GlobalShortcut
    var allowsFunctionModifier = false
    var allowsMouseButton = false
    let onChange: (GlobalShortcut) -> Bool

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button(recordingPrompt) {
                isRecording ? stopRecording() : startRecording()
            }
            .dictatorButton(isRecording ? .primary : .secondary)
            .frame(minWidth: 112)
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
        var eventMask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged]
        if allowsMouseButton {
            eventMask.insert(.otherMouseDown)
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) { event in
            if event.type == .otherMouseDown {
                let buttonNumber = Int64(event.buttonNumber)
                guard let shortcut = GlobalShortcut(mouseButtonNumber: buttonNumber) else {
                    return event
                }
                accept(shortcut)
                return nil
            }

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
    }

    private var recordingPrompt: String {
        guard isRecording else { return shortcut.displayName }
        return allowsMouseButton ? "Press key or mouse button…" : "Type shortcut…"
    }

    private func accept(_ captured: GlobalShortcut) {
        if onChange(captured) {
            stopRecording()
        } else {
            hint = "That shortcut is already in use"
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
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
