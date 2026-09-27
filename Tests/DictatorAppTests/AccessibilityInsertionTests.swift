import ApplicationServices
import AppKit
import Foundation
import XCTest
@testable import Dictator

@MainActor
final class AccessibilityInsertionTests: XCTestCase {
    func testResolverPrefersExactEditableTarget() {
        let fixture = InsertionFixture()

        let target = AccessibilityTargetResolver.resolve(
            application: fixture.application,
            candidates: [
                .editable(
                    processIdentifier: fixture.targetPID,
                    element: fixture.fieldElement,
                    selection: fixture.originalSelection
                )
            ]
        )

        guard case .field(let application, let element, let selection) = target else {
            return XCTFail("Expected an exact field target")
        }
        XCTAssertEqual(application.processIdentifier, fixture.targetPID)
        XCTAssertTrue(CFEqual(element, fixture.fieldElement))
        XCTAssertEqual(selection, fixture.originalSelection)
    }

    func testResolverUsesApplicationFallbackWithoutAllowlist() {
        let fixture = InsertionFixture(bundleIdentifier: "com.example.custom-editor")

        let target = AccessibilityTargetResolver.resolve(application: fixture.application, candidates: [])

        guard case .application(let application) = target else {
            return XCTFail("Expected an application fallback")
        }
        XCTAssertEqual(application.bundleIdentifier, "com.example.custom-editor")
    }

    func testResolverBlocksKnownSecureField() async {
        let fixture = InsertionFixture()
        let target = AccessibilityTargetResolver.resolve(
            application: fixture.application,
            candidates: [.secure(processIdentifier: fixture.targetPID)]
        )

        let result = await fixture.inserter.insert(.dictation("secret"), into: target)

        XCTAssertEqual(result, .privateClipboard("secure fields are never modified"))
        XCTAssertTrue(fixture.events.events.isEmpty)
    }

    func testResolverIgnoresFocusedCandidateFromAnotherProcess() {
        let fixture = InsertionFixture()

        let target = AccessibilityTargetResolver.resolve(
            application: fixture.application,
            candidates: [.secure(processIdentifier: 777)]
        )

        guard case .application = target else {
            return XCTFail("A candidate from another process must not become the target")
        }
    }

    func testApplicationFallbackPastesWhenOriginalAppRemainsFrontmost() async {
        let fixture = InsertionFixture(bundleIdentifier: "com.openai.codex")

        let result = await fixture.inserter.insert(.dictation("hello ChatGPT"), into: .application(fixture.application))

        XCTAssertEqual(result, .pasteCommandPosted(.activeApplication))
        XCTAssertEqual(fixture.events.events, Self.expectedPasteEvents)
        // The pasteboard restore now runs in a detached task after `insert`
        // returns, so give it a moment to complete before checking it.
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(fixture.clipboard.didRestore)
    }

    func testInsertionPreservesParagraphBreaks() async {
        let fixture = InsertionFixture(bundleIdentifier: "com.apple.mail")
        let email = "Hi Sam,\n\nThanks for the update. I will review it today.\n\nBest,\nAmal"

        let result = await fixture.inserter.insert(.dictation(email), into: .application(fixture.application))

        XCTAssertEqual(result, .pasteCommandPosted(.activeApplication))
        XCTAssertEqual(fixture.clipboard.lastPreparedText, email)
    }

    func testApplicationFallbackDoesNotPasteAfterAppSwitch() async {
        let fixture = InsertionFixture()
        fixture.applicationState.frontmostPID = 777

        let result = await fixture.inserter.insert(.dictation("do not paste"), into: .application(fixture.application))

        XCTAssertEqual(result, .privateClipboard("focus moved to another application"))
        XCTAssertTrue(fixture.events.events.isEmpty)
    }

    func testDeadTargetFallsBackToPrivateClipboard() async {
        let fixture = InsertionFixture()
        fixture.applicationState.runningPIDs.remove(fixture.targetPID)

        let result = await fixture.inserter.insert(.dictation("do not paste"), into: .application(fixture.application))

        XCTAssertEqual(result, .privateClipboard("the target application is no longer running"))
        XCTAssertTrue(fixture.events.events.isEmpty)
    }

    func testExactTargetReactivatesAndPastesEvenWhenAXRefocusIsRejected() async {
        let fixture = InsertionFixture()
        fixture.applicationState.frontmostPID = 777
        fixture.applicationState.focusSucceeds = false

        let result = await fixture.inserter.insert(
            .dictation("exact"),
            into: .field(application: fixture.application, element: fixture.fieldElement, selection: nil)
        )

        XCTAssertEqual(result, .pasteCommandPosted(.capturedField))
        XCTAssertEqual(fixture.applicationState.activatedPIDs, [fixture.targetPID])
        XCTAssertEqual(fixture.applicationState.focusAttempts, 1)
        XCTAssertEqual(fixture.events.events, Self.expectedPasteEvents)
    }

    func testPasteEventFailureRestoresOwnedClipboard() async {
        let fixture = InsertionFixture()
        fixture.events.failureIndex = 1

        let result = await fixture.inserter.insert(.dictation("failed"), into: .application(fixture.application))

        XCTAssertEqual(result, .privateClipboard("the paste shortcut could not be posted"))
        XCTAssertTrue(fixture.clipboard.didRestore)
    }

    func testClipboardPreparationFailureRestoresSnapshot() async {
        let fixture = InsertionFixture()
        fixture.clipboard.prepareSucceeds = false

        let result = await fixture.inserter.insert(.dictation("failed"), into: .application(fixture.application))

        XCTAssertEqual(result, .privateClipboard("the paste shortcut could not be posted"))
        XCTAssertTrue(fixture.clipboard.didRestore)
        XCTAssertTrue(fixture.events.events.isEmpty)
    }

    func testExternallyChangedClipboardIsNotOverwritten() async {
        let fixture = InsertionFixture()
        fixture.clipboard.ownsPreparedContents = false

        let result = await fixture.inserter.insert(.dictation("paste"), into: .application(fixture.application))

        XCTAssertEqual(result, .pasteCommandPosted(.activeApplication))
        XCTAssertFalse(fixture.clipboard.didRestore)
    }

    func testTransformationPastesWhenCapturedSelectionStillMatches() async {
        let fixture = InsertionFixture()

        let result = await fixture.inserter.insert(
            .transformation("selected text", expectedSelection: fixture.originalSelection),
            into: .field(
                application: fixture.application,
                element: fixture.fieldElement,
                selection: fixture.originalSelection
            )
        )

        XCTAssertEqual(result, .pasteCommandPosted(.capturedField))
        XCTAssertEqual(fixture.events.events, Self.expectedPasteEvents)
    }

    func testTransformationDoesNotPasteAfterSelectionChanges() async {
        let fixture = InsertionFixture()
        fixture.applicationState.currentSelection = TextSelectionSnapshot(
            text: "DIFFERENT TEXT",
            location: 20,
            length: 14
        )

        let result = await fixture.inserter.insert(
            .transformation("selected text", expectedSelection: fixture.originalSelection),
            into: .field(
                application: fixture.application,
                element: fixture.fieldElement,
                selection: fixture.originalSelection
            )
        )

        XCTAssertEqual(result, .privateClipboard("the selected text changed before transformation"))
        XCTAssertTrue(fixture.events.events.isEmpty)
    }

    /// Before the merged walk, `captureFocusedTarget` always fetched both the
    /// system-wide AND app-scoped focused elements (usually the same one),
    /// then ran two independent 8-hop ancestor walks (secure, then editable)
    /// per fetched element. For this 6-deep non-secure editable target that
    /// is 2 initial fetches + 2 x (14-call secure walk + 26-call editable
    /// walk) = 82 attribute/settable fetches. The merged walk below fetches
    /// only the system-wide element and walks the ancestor chain once.
    func testCaptureFocusedTargetWalksAncestorsOnceForASixDeepEditableTarget() {
        let oldDesignCallCount = 82
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let walk = FakeAccessibilityWalk()
        let leaf = walk.addNode(pid: ownPID)
        var parentPID = ownPID
        for depth in 1...6 {
            let pid = ownPID + pid_t(depth)
            walk.addNode(pid: pid, valueSettable: depth == 6)
            walk.setParent(ofPID: parentPID, toPID: pid)
            parentPID = pid
        }
        walk.focusedElement = leaf

        let resolver = AccessibilityTargetResolver(primitives: walk.primitives)
        let target = resolver.captureFocusedTarget(processIdentifier: ownPID)

        guard case .field = target else {
            return XCTFail("Expected the 6-deep non-secure target to resolve as an editable field")
        }
        XCTAssertEqual(walk.rootQueryCount, 1, "the app element must not be queried once the system-wide lookup succeeds")
        XCTAssertEqual(walk.callCount, 34, "old design: \(oldDesignCallCount) calls; new merged/deduped walk: \(walk.callCount)")
        XCTAssertLessThanOrEqual(walk.callCount, oldDesignCallCount / 2)
    }

    private static let expectedPasteEvents = [
        PostedKeyEvent(keyCode: 0x09, keyDown: true, flags: .maskCommand),
        PostedKeyEvent(keyCode: 0x09, keyDown: false, flags: .maskCommand),
    ]
}

/// A synthetic focused-element ancestor chain used to exercise
/// `AccessibilityTargetResolver`'s walk without live AXUIElements. Nodes are
/// keyed by the pid given to `AXUIElementCreateApplication`, which is a
/// stable identifier for these fake elements even without Accessibility
/// trust. Any queried element that isn't a registered node is treated as one
/// of the two capture roots (system-wide or the app element) and only
/// answers the focused-element attribute.
@MainActor
final class FakeAccessibilityWalk {
    private struct Node {
        var subrole: String?
        var role: String?
        var selectedTextSettable = false
        var valueSettable = false
        var parent: AXUIElement?
    }

    private var nodes: [pid_t: Node] = [:]
    private var elements: [pid_t: AXUIElement] = [:]
    private(set) var callCount = 0
    private(set) var rootQueryCount = 0
    var focusedElement: AXUIElement?

    @discardableResult
    func addNode(
        pid: pid_t,
        subrole: String? = nil,
        role: String? = nil,
        selectedTextSettable: Bool = false,
        valueSettable: Bool = false
    ) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        nodes[pid] = Node(
            subrole: subrole,
            role: role,
            selectedTextSettable: selectedTextSettable,
            valueSettable: valueSettable
        )
        elements[pid] = element
        return element
    }

    func setParent(ofPID childPID: pid_t, toPID parentPID: pid_t) {
        nodes[childPID]?.parent = elements[parentPID]
    }

    private func pid(of element: AXUIElement) -> pid_t? {
        var value: pid_t = 0
        return AXUIElementGetPid(element, &value) == .success ? value : nil
    }

    var primitives: AccessibilityWalkPrimitives {
        AccessibilityWalkPrimitives(
            copyAttribute: { [weak self] element, attribute in
                guard let self else { return nil }
                guard let pid = self.pid(of: element), let node = self.nodes[pid] else {
                    guard attribute as String == kAXFocusedUIElementAttribute else { return nil }
                    self.rootQueryCount += 1
                    self.callCount += 1
                    return self.focusedElement
                }
                self.callCount += 1
                switch attribute as String {
                case kAXParentAttribute: return node.parent
                case kAXSubroleAttribute: return node.subrole as CFTypeRef?
                case kAXRoleAttribute: return node.role as CFTypeRef?
                default: return nil
                }
            },
            isAttributeSettable: { [weak self] element, attribute in
                guard let self, let pid = self.pid(of: element), let node = self.nodes[pid] else { return false }
                self.callCount += 1
                switch attribute as String {
                case kAXSelectedTextAttribute: return node.selectedTextSettable
                case kAXValueAttribute: return node.valueSettable
                default: return false
                }
            },
            setMessagingTimeout: { _, _ in }
        )
    }
}

@MainActor
final class InsertionFixture {
    let targetPID: pid_t = 4242
    let applicationElement = AXUIElementCreateApplication(4242)
    let fieldElement = AXUIElementCreateApplication(4242)
    let applicationState = TestApplicationState()
    let clipboard = TestClipboard()
    let events = TestEventRecorder()
    let originalSelection = TextSelectionSnapshot(text: "SELECTED TEXT", location: 0, length: 13)
    let application: ApplicationTarget
    let inserter: AccessibilityInserter

    init(bundleIdentifier: String = "com.example.editor") {
        application = ApplicationTarget(
            element: applicationElement,
            name: "Test App",
            bundleIdentifier: bundleIdentifier,
            processIdentifier: targetPID
        )
        applicationState.frontmostPID = targetPID
        applicationState.runningPIDs = [targetPID, 777]
        applicationState.currentSelection = originalSelection

        let state = applicationState
        let eventRecorder = events
        let environment = InsertionEnvironment(
            frontmostProcessIdentifier: { state.frontmostPID },
            isRunning: { state.runningPIDs.contains($0) },
            activate: {
                state.activatedPIDs.append($0)
                return state.activationSucceeds
            },
            focus: { _ in
                state.focusAttempts += 1
                return state.focusSucceeds
            },
            selection: { _ in state.currentSelection },
            delay: { _ in }
        )
        let paster = ClipboardPaster(
            clipboard: clipboard,
            postEvent: { eventRecorder.post($0) },
            delay: { _ in }
        )
        inserter = AccessibilityInserter(environment: environment, paster: paster)
    }
}

@MainActor
final class TestApplicationState {
    var frontmostPID: pid_t?
    var runningPIDs: Set<pid_t> = []
    var activatedPIDs: [pid_t] = []
    var activationSucceeds = true
    var focusSucceeds = true
    var focusAttempts = 0
    var currentSelection: TextSelectionSnapshot?
}

@MainActor
final class TestClipboard: ClipboardAccess {
    var ownsPreparedContents = true
    var prepareSucceeds = true
    var didRestore = false
    private var preparedText: String?
    private var preparedSessionID: String?
    var lastPreparedText: String? { preparedText }

    func snapshot() -> PasteboardSnapshot { PasteboardSnapshot(items: []) }
    func prepare(text: String, sessionID: String) -> Bool {
        preparedText = text
        preparedSessionID = sessionID
        return prepareSucceeds
    }
    func owns(text: String, sessionID: String) -> Bool {
        ownsPreparedContents && text == preparedText && sessionID == preparedSessionID
    }
    func restore(_ snapshot: PasteboardSnapshot) { didRestore = true }
}

@MainActor
final class TestEventRecorder {
    var events: [PostedKeyEvent] = []
    var failureIndex: Int?

    func post(_ event: PostedKeyEvent) -> Bool {
        let index = events.count
        events.append(event)
        return index != failureIndex
    }
}
