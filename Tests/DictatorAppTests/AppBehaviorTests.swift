import CoreGraphics
import XCTest
@testable import Dictator

@MainActor
final class AppBehaviorTests: XCTestCase {
    func testPrivateClipboardShortcutsAreExact() {
        let shortcut = GlobalShortcut(keyCode: 8, modifiers: [.maskCommand, .maskControl], keyLabel: "C")
        XCTAssertTrue(ShortcutMatcher.matches(shortcut, keyCode: 8, flags: [.maskCommand, .maskControl]))
        XCTAssertFalse(ShortcutMatcher.matches(shortcut, keyCode: 8, flags: [.maskCommand]))
        XCTAssertFalse(ShortcutMatcher.matches(shortcut, keyCode: 9, flags: [.maskCommand, .maskControl]))
        XCTAssertEqual(shortcut.displayName, "⌃⌘C")
    }

    func testMissingFocusedTargetNeverTouchesAnotherApp() async {
        let result = await AccessibilityInserter().insert("private text", into: nil)
        XCTAssertEqual(result, .privateClipboard("no editable field was focused"))
    }
}
