import AppKit
import Foundation
import XCTest
@testable import Dictator

@MainActor
final class FloatingHUDTests: XCTestCase {
    func testHUDShowsOnlyOneVisiblePanel() {
        let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let controller = FloatingPanelController()

        controller.show(.listening)

        let panels = NSApp.windows.filter {
            !existingWindows.contains(ObjectIdentifier($0)) && $0 is NSPanel
        }
        defer { panels.forEach { $0.close() } }
        XCTAssertEqual(panels.filter(\.isVisible).count, 1)
    }

    func testHUDHideAfterDelayOrdersPanelOut() async throws {
        let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let controller = FloatingPanelController()
        controller.show(.error("Too short"))
        let panel = try XCTUnwrap(NSApp.windows.first {
            !existingWindows.contains(ObjectIdentifier($0)) && $0 is NSPanel
        })
        defer { panel.close() }

        controller.hideAfterDelay()
        try await Task.sleep(for: .milliseconds(1_300))

        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(controller.model.phase, .idle)
    }

    func testHUDReanchorsAfterScreenParametersChange() async throws {
        let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let controller = FloatingPanelController()
        controller.show(.listening)
        let panel = try XCTUnwrap(NSApp.windows.first {
            !existingWindows.contains(ObjectIdentifier($0)) && $0 is NSPanel
        })
        defer { panel.close() }
        let anchored = panel.frame
        panel.setFrameOrigin(NSPoint(x: anchored.minX - 180, y: anchored.minY - 120))
        XCTAssertNotEqual(panel.frame.origin, anchored.origin, "Test must move the panel off its anchor")
        let didMove = expectation(forNotification: NSWindow.didMoveNotification, object: panel)

        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: NSApp
        )

        await fulfillment(of: [didMove], timeout: 1)
        XCTAssertEqual(panel.frame.origin.x, anchored.origin.x, accuracy: 1)
        XCTAssertEqual(panel.frame.origin.y, anchored.origin.y, accuracy: 1)
        withExtendedLifetime(controller) {}
    }

    func testHUDOnlyAcceptsMouseEventsWhileListening() throws {
        let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let controller = FloatingPanelController()
        controller.show(.listening)
        let panel = try XCTUnwrap(NSApp.windows.first {
            !existingWindows.contains(ObjectIdentifier($0)) && $0 is NSPanel
        })
        defer { panel.close() }

        XCTAssertFalse(panel.ignoresMouseEvents)
        controller.show(.transcribing)
        XCTAssertTrue(panel.ignoresMouseEvents)
    }

    func testHUDStopButtonRoutesToRecordingStopAction() {
        let controller = FloatingPanelController()
        var stopCount = 0
        controller.onStop = { stopCount += 1 }
        controller.show(.listening)

        controller.stopFromPill()

        XCTAssertEqual(stopCount, 1)
    }

    func testHUDNotchFramePinsToTopCenter() {
        XCTAssertEqual(
            HUDPositioning.notchFrame(
                size: NSSize(width: 124, height: 32),
                screenFrame: NSRect(x: 0, y: 0, width: 1_440, height: 900),
                topExclusion: 24
            ),
            NSRect(x: 658, y: 840, width: 124, height: 32)
        )
    }

    func testHUDTopExclusionUsesLargerOfNotchAndMenuBar() {
        XCTAssertEqual(
            HUDPositioning.topExclusion(
                screenFrame: NSRect(x: 0, y: 0, width: 1_512, height: 982),
                visibleFrame: NSRect(x: 0, y: 0, width: 1_512, height: 950),
                topSafeAreaInset: 38
            ),
            38
        )
        XCTAssertEqual(
            HUDPositioning.notchFrame(
                size: NSSize(width: 124, height: 32),
                screenFrame: NSRect(x: 0, y: 0, width: 1_512, height: 982),
                topExclusion: 38
            ),
            NSRect(x: 694, y: 908, width: 124, height: 32)
        )
    }

    func testHUDSuccessPresentationDefinesItsOwnLabelAndWidth() {
        let presentations: [(HUDSuccess, String, CGFloat)] = [
            (.cancelled, "Cancelled", 124),
            (.copied, "Copied — press ⌘V", 196),
            (.pasteSent, "Paste sent", 124),
            (.offlineSaved, "Offline · Saved", 174),
            (.offlineCopied, "Offline · Copied", 196),
            (.offlinePasteSent, "Offline · Paste sent", 174),
        ]

        for (success, label, width) in presentations {
            XCTAssertEqual(success.label, label)
            XCTAssertEqual(success.panelWidth, width)
            XCTAssertEqual(HUDPhase.success(success).label, label)
        }
    }
}
