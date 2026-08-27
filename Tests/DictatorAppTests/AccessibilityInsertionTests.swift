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

    private static let expectedPasteEvents = [
        PostedKeyEvent(keyCode: 0x09, keyDown: true, flags: .maskCommand),
        PostedKeyEvent(keyCode: 0x09, keyDown: false, flags: .maskCommand),
    ]
}
