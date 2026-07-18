import CoreGraphics
import XCTest
@testable import Dictator

@MainActor
final class HotkeyMonitorTests: XCTestCase {
    func testPrivateClipboardShortcutsAreExact() {
        let shortcut = GlobalShortcut(
            keyCode: 8,
            modifiers: [.maskCommand, .maskControl],
            keyLabel: "C"
        )

        XCTAssertTrue(
            ShortcutMatcher.matches(
                shortcut,
                keyCode: 8,
                flags: [.maskCommand, .maskControl]
            )
        )
        XCTAssertFalse(
            ShortcutMatcher.matches(shortcut, keyCode: 8, flags: [.maskCommand])
        )
        XCTAssertFalse(
            ShortcutMatcher.matches(
                shortcut,
                keyCode: 9,
                flags: [.maskCommand, .maskControl]
            )
        )
        XCTAssertEqual(shortcut.displayName, "⌃⌘C")
    }

    func testScreenAwareShortcutIsAnExactModifierChord() throws {
        let shortcut = GlobalShortcut.screenAware
        guard case .modifierChord(let modifiersRawValue) = shortcut.trigger else {
            return XCTFail("Expected a typed modifier chord")
        }
        XCTAssertEqual(
            CGEventFlags(rawValue: modifiersRawValue),
            [.maskControl, .maskAlternate]
        )
        XCTAssertEqual(shortcut.displayName, "⌃⌥")
        XCTAssertTrue(
            ShortcutMatcher.matchesModifiers(
                shortcut,
                flags: [.maskControl, .maskAlternate]
            )
        )
        XCTAssertFalse(
            ShortcutMatcher.matchesModifiers(shortcut, flags: [.maskControl])
        )
        XCTAssertFalse(
            ShortcutMatcher.matchesModifiers(
                shortcut,
                flags: [.maskControl, .maskAlternate, .maskShift]
            )
        )

        let restored = try JSONDecoder().decode(
            GlobalShortcut.self,
            from: JSONEncoder().encode(shortcut)
        )
        XCTAssertEqual(restored, shortcut)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(shortcut)
            ) as? [String: Any]
        )
        XCTAssertNotNil(object["trigger"])
        XCTAssertNil(object["keyCode"])
        XCTAssertNil(object["isFunctionModifier"])
        XCTAssertNil(object["isModifierOnly"])
    }

    func testLegacyShortcutDecodesIntoTypedKeyTrigger() throws {
        let legacy = #"{"keyCode":8,"modifiersRawValue":1179648,"keyLabel":"C","isFunctionModifier":false,"isModifierOnly":false}"#

        let shortcut = try JSONDecoder().decode(
            GlobalShortcut.self,
            from: Data(legacy.utf8)
        )

        guard case .key(let keyCode, _, let label) = shortcut.trigger else {
            return XCTFail("Expected a typed key trigger")
        }
        XCTAssertEqual(keyCode, 8)
        XCTAssertEqual(label, "C")
    }

    func testHotkeyHealthRequiresValidEnabledTap() {
        XCTAssertTrue(
            HotkeyMonitor.isTapHealthy(isValid: true, isEnabled: true)
        )
        XCTAssertFalse(
            HotkeyMonitor.isTapHealthy(isValid: false, isEnabled: true)
        )
        XCTAssertFalse(
            HotkeyMonitor.isTapHealthy(isValid: true, isEnabled: false)
        )
    }
}
