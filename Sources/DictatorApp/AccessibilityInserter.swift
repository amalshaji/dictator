import AppKit
import ApplicationServices
import Foundation

struct FocusedTarget {
    let element: AXUIElement
    let bundleIdentifier: String?
    let processIdentifier: pid_t
    let shouldRefocusElement: Bool
}

enum InsertionResult: Equatable {
    case accessibility
    case pasteboardFallback
    case privateClipboard(String)

    var label: String {
        switch self {
        case .accessibility: "Inserted"
        case .pasteboardFallback: "Inserted with paste fallback"
        case .privateClipboard(let reason): "Saved to private clipboard: \(reason)"
        }
    }
}

@MainActor
final class AccessibilityInserter {
    func captureFocusedTarget() -> FocusedTarget? {
        let system = AXUIElementCreateSystemWide()
        var candidates: [AXUIElement] = []
        if let focused = focusedElement(in: system) { candidates.append(focused) }

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        var applicationElement: AXUIElement?
        if let app = frontmostApp {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            applicationElement = element
            if let focused = focusedElement(in: element) { candidates.append(focused) }
        }

        if let axElement = candidates.lazy.compactMap(editableAncestor(from:)).first {
            var pid: pid_t = 0
            AXUIElementGetPid(axElement, &pid)
            let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            return FocusedTarget(element: axElement, bundleIdentifier: bundle, processIdentifier: pid, shouldRefocusElement: true)
        }

        // Chromium and Firefox can withhold the focused web control until their
        // accessibility tree is activated. The nonactivating HUD leaves the web
        // responder untouched, so retain the browser and paste back into it later.
        if let app = frontmostApp, let applicationElement, isBrowser(app) {
            return FocusedTarget(
                element: applicationElement,
                bundleIdentifier: app.bundleIdentifier,
                processIdentifier: app.processIdentifier,
                shouldRefocusElement: false
            )
        }
        return nil
    }

    func insert(_ text: String, into target: FocusedTarget?) async -> InsertionResult {
        guard let target else { return .privateClipboard("no editable field was focused") }
        if target.shouldRefocusElement, isSecure(target.element) {
            return .privateClipboard("secure fields are never modified")
        }

        // AXSelectedText frequently reports success without changing Chromium,
        // Electron, and some SwiftUI editors. Refocus the element captured when
        // recording began and use a clipboard-preserving paste as the primary path.
        let needsActivation = NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier
        if needsActivation {
            NSRunningApplication(processIdentifier: target.processIdentifier)?.activate()
            try? await Task.sleep(for: .milliseconds(180))
        }
        if target.shouldRefocusElement {
            _ = AXUIElementSetAttributeValue(target.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            try? await Task.sleep(for: .milliseconds(40))
        }
        guard await pastePreservingClipboard(text) else {
            return .privateClipboard("the paste shortcut could not be posted")
        }
        return .pasteboardFallback
    }

    /// The user explicitly invoked Paste Latest, so let the frontmost app decide
    /// whether its current responder accepts paste instead of requiring AX support.
    func pasteIntoFrontmostApp(_ text: String) async -> Bool {
        await pastePreservingClipboard(text)
    }

    private func pastePreservingClipboard(_ text: String) async -> Bool {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            snapshot.restore(to: pasteboard)
            return false
        }
        let writtenChangeCount = pasteboard.changeCount
        guard postPaste() else {
            snapshot.restore(to: pasteboard)
            return false
        }
        // Web-based editors may read the pasteboard on a later run-loop turn.
        try? await Task.sleep(for: .milliseconds(350))
        if pasteboard.changeCount == writtenChangeCount { snapshot.restore(to: pasteboard) }
        return true
    }

    private func focusedElement(in root: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let element = axElement(value)
        else { return nil }
        return element
    }

    private func editableAncestor(from element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<8 {
            guard let candidate = current else { return nil }
            if isEditable(candidate) { return candidate }
            var parentValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(candidate, kAXParentAttribute as CFString, &parentValue) == .success,
                  let parent = axElement(parentValue)
            else { return nil }
            current = parent
        }
        return nil
    }

    private func isBrowser(_ application: NSRunningApplication) -> Bool {
        let identifier = application.bundleIdentifier?.lowercased() ?? ""
        let name = application.localizedName?.lowercased() ?? ""
        let knownIdentifiers = [
            "com.apple.safari", "com.google.chrome", "company.thebrowser.browser",
            "com.brave.browser", "com.microsoft.edgemac", "org.mozilla.firefox",
            "com.vivaldi.vivaldi", "com.operasoftware.opera", "com.kagi.kagimacos",
            "ai.perplexity.comet"
        ]
        return knownIdentifiers.contains(where: identifier.hasPrefix)
            || ["chrome", "chromium", "firefox", "safari", "arc", "brave", "edge", "orion", "vivaldi", "opera", "comet"]
                .contains(where: name.contains)
    }

    private func isEditable(_ element: AXUIElement) -> Bool {
        var selectedTextSettable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &selectedTextSettable) == .success,
           selectedTextSettable.boolValue { return true }

        var valueSettable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueSettable) == .success,
           valueSettable.boolValue { return true }

        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
              let role = roleValue as? String else { return false }
        return [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"].contains(role)
    }

    private func isSecure(_ element: AXUIElement) -> Bool {
        var subroleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleValue) == .success,
              let subrole = subroleValue as? String else { return false }
        return subrole == kAXSecureTextFieldSubrole
    }

    private func axElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func postPaste() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}

private struct PasteboardSnapshot {
    struct Item { let values: [NSPasteboard.PasteboardType: Data] }
    let items: [Item]

    init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            Item(values: Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            }))
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.map { item -> NSPasteboardItem in
            let value = NSPasteboardItem()
            for (type, data) in item.values { value.setData(data, forType: type) }
            return value
        }
        pasteboard.writeObjects(restored)
    }
}
