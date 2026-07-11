import AppKit
import ApplicationServices
import Foundation

struct ApplicationTarget {
    let element: AXUIElement
    let bundleIdentifier: String?
    let processIdentifier: pid_t
}

enum FocusedTarget {
    case field(application: ApplicationTarget, element: AXUIElement, selectedText: String?)
    case application(ApplicationTarget)
    case blocked(application: ApplicationTarget, reason: String)

    var application: ApplicationTarget {
        switch self {
        case .field(let application, _, _), .application(let application), .blocked(let application, _):
            application
        }
    }

    var bundleIdentifier: String? { application.bundleIdentifier }

    var selectedText: String? {
        guard case .field(_, _, let selectedText) = self else { return nil }
        return selectedText
    }
}

enum PasteDestination: Equatable {
    case capturedField
    case activeApplication
}

enum InsertionResult: Equatable {
    case pasteCommandPosted(PasteDestination)
    case privateClipboard(String)

    var label: String {
        switch self {
        case .pasteCommandPosted(.capturedField): "Paste command sent to captured field"
        case .pasteCommandPosted(.activeApplication): "Paste command sent to active application"
        case .privateClipboard(let reason): "Saved to private clipboard: \(reason)"
        }
    }
}

struct TargetCandidate {
    let processIdentifier: pid_t
    let editableElement: AXUIElement?
    let selectedText: String?
    let isSecure: Bool
}

struct AccessibilityTargetResolver {
    func captureFocusedTarget(processIdentifier: pid_t? = nil) -> FocusedTarget? {
        let eventTarget = processIdentifier.flatMap(NSRunningApplication.init(processIdentifier:))
        guard let runningApplication = eventTarget ?? targetApplication() else { return nil }
        let application = ApplicationTarget(
            element: AXUIElementCreateApplication(runningApplication.processIdentifier),
            bundleIdentifier: runningApplication.bundleIdentifier,
            processIdentifier: runningApplication.processIdentifier
        )

        let system = AXUIElementCreateSystemWide()
        let elements = [focusedElement(in: system), focusedElement(in: application.element)].compactMap { $0 }
        let candidates = elements.compactMap(candidate(from:))
        return Self.resolve(application: application, candidates: candidates)
    }

    private func targetApplication() -> NSRunningApplication? {
        if let frontmost = NSWorkspace.shared.frontmostApplication { return frontmost }

        // The workspace notification can briefly clear `frontmostApplication`
        // while a global event-tap callback is being delivered. The app that
        // AppKit still marks active is the same user-selected destination.
        if let active = NSWorkspace.shared.runningApplications.first(where: {
            $0.isActive && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }) { return active }

        // Some agent-style apps have no conventional active application during
        // modifier event delivery. Window Server still exposes the ordered
        // on-screen window owners, so use the first normal application window.
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for window in windows {
            guard (window[kCGWindowLayer] as? NSNumber)?.intValue == 0,
                  let ownerPID = (window[kCGWindowOwnerPID] as? NSNumber)?.int32Value,
                  ownerPID != ownPID,
                  let application = NSRunningApplication(processIdentifier: ownerPID),
                  application.activationPolicy != .prohibited
            else { continue }
            return application
        }
        return nil
    }

    static func resolve(application: ApplicationTarget, candidates: [TargetCandidate]) -> FocusedTarget {
        let applicationCandidates = candidates.filter { $0.processIdentifier == application.processIdentifier }
        if applicationCandidates.contains(where: \.isSecure) {
            return .blocked(application: application, reason: "secure fields are never modified")
        }
        if let candidate = applicationCandidates.first(where: { $0.editableElement != nil }),
           let element = candidate.editableElement {
            return .field(application: application, element: element, selectedText: candidate.selectedText)
        }
        return .application(application)
    }

    private func candidate(from element: AXUIElement) -> TargetCandidate? {
        var candidatePID: pid_t = 0
        guard AXUIElementGetPid(element, &candidatePID) == .success else { return nil }
        let editableElement = firstAncestor(from: element, matching: isEditable)
        return TargetCandidate(
            processIdentifier: candidatePID,
            editableElement: editableElement,
            selectedText: editableElement.flatMap(selectedText(in:)),
            isSecure: firstAncestor(from: element, matching: isSecure) != nil
        )
    }

    private func selectedText(in element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String,
              !text.isEmpty
        else { return nil }
        return text
    }

    private func focusedElement(in root: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &value) == .success
        else { return nil }
        return axElement(value)
    }

    private func firstAncestor(
        from element: AXUIElement,
        matching predicate: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<8 {
            guard let candidate = current else { return nil }
            if predicate(candidate) { return candidate }
            var parentValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(candidate, kAXParentAttribute as CFString, &parentValue) == .success,
                  let parent = axElement(parentValue)
            else { return nil }
            current = parent
        }
        return nil
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
}

@MainActor
struct InsertionEnvironment {
    let frontmostProcessIdentifier: () -> pid_t?
    let isRunning: (pid_t) -> Bool
    let activate: (pid_t) -> Bool
    let focus: (AXUIElement) -> Bool
    let delay: (Int) async -> Void

    static let live = InsertionEnvironment(
        frontmostProcessIdentifier: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
        isRunning: { NSRunningApplication(processIdentifier: $0) != nil },
        activate: { NSRunningApplication(processIdentifier: $0)?.activate() ?? false },
        focus: {
            AXUIElementSetAttributeValue($0, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
        },
        delay: { try? await Task.sleep(for: .milliseconds($0)) }
    )
}

@MainActor
final class AccessibilityInserter {
    private let resolver: AccessibilityTargetResolver
    private let environment: InsertionEnvironment
    private let paster: ClipboardPaster

    init() {
        resolver = AccessibilityTargetResolver()
        environment = .live
        paster = ClipboardPaster()
    }

    init(
        resolver: AccessibilityTargetResolver = AccessibilityTargetResolver(),
        environment: InsertionEnvironment,
        paster: ClipboardPaster
    ) {
        self.resolver = resolver
        self.environment = environment
        self.paster = paster
    }

    func captureFocusedTarget(processIdentifier: pid_t? = nil) -> FocusedTarget? {
        resolver.captureFocusedTarget(processIdentifier: processIdentifier)
    }

    func insert(_ text: String, into target: FocusedTarget?) async -> InsertionResult {
        guard let target else { return .privateClipboard("no editable field was focused") }

        switch target {
        case .field(let application, let element, _):
            guard environment.isRunning(application.processIdentifier) else {
                return .privateClipboard("the target application is no longer running")
            }
            if environment.frontmostProcessIdentifier() != application.processIdentifier {
                guard environment.activate(application.processIdentifier) else {
                    return .privateClipboard("the target application could not be activated")
                }
                await environment.delay(180)
            }
            // AX focus is advisory. Some valid custom editors reject this write
            // while retaining a responder that still accepts the paste command.
            _ = environment.focus(element)
            await environment.delay(40)
            guard await paster.paste(text) else {
                return .privateClipboard("the paste shortcut could not be posted")
            }
            return .pasteCommandPosted(.capturedField)

        case .application(let application):
            guard environment.isRunning(application.processIdentifier) else {
                return .privateClipboard("the target application is no longer running")
            }
            guard environment.frontmostProcessIdentifier() == application.processIdentifier else {
                return .privateClipboard("focus moved to another application")
            }
            guard await paster.paste(text) else {
                return .privateClipboard("the paste shortcut could not be posted")
            }
            return .pasteCommandPosted(.activeApplication)

        case .blocked(_, let reason):
            return .privateClipboard(reason)
        }
    }

    /// Paste Latest is explicitly user-directed, so the current responder owns
    /// destination selection and no captured Accessibility target is required.
    func pasteIntoFrontmostApp(_ text: String) async -> Bool {
        await paster.paste(text)
    }
}
