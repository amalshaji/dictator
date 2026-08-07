import CoreGraphics
import XCTest
@testable import Dictator

final class HotkeyEventTapContextTests: XCTestCase {
    func testFunctionModifierTransitionsEmitOnePressAndReleaseWithoutConsumingEvents() throws {
        let context = makeContext()
        let down = try makeEvent(flags: .maskSecondaryFn, targetProcessIdentifier: 42)
        let up = try makeEvent(flags: [])

        XCTAssertEqual(
            context.process(down, type: .flagsChanged),
            HotkeyEventOutcome(action: .press(42), consumesEvent: false)
        )
        XCTAssertEqual(context.process(down, type: .flagsChanged), .ignored)
        XCTAssertEqual(
            context.process(up, type: .flagsChanged),
            HotkeyEventOutcome(action: .release, consumesEvent: false)
        )
    }

    func testReplacingContextClearsHeldFunctionModifierState() throws {
        let firstContext = makeContext()
        let down = try makeEvent(flags: .maskSecondaryFn)

        XCTAssertEqual(
            firstContext.process(down, type: .flagsChanged).action,
            .press(nil)
        )
        let replacementContext = makeContext()

        XCTAssertEqual(
            replacementContext.process(down, type: .flagsChanged).action,
            .press(nil)
        )
    }

    func testToggleActivationEmitsAPressPerFunctionModifierDownAndNoRelease() throws {
        let context = makeContext(dictateActivation: .toggle)
        let down = try makeEvent(flags: .maskSecondaryFn, targetProcessIdentifier: 42)
        let up = try makeEvent(flags: [])

        XCTAssertEqual(
            context.process(down, type: .flagsChanged),
            HotkeyEventOutcome(action: .press(42), consumesEvent: false)
        )
        XCTAssertEqual(
            context.process(up, type: .flagsChanged),
            HotkeyEventOutcome(action: nil, consumesEvent: false)
        )
        XCTAssertEqual(
            context.process(down, type: .flagsChanged),
            HotkeyEventOutcome(action: .press(42), consumesEvent: false)
        )
    }

    func testToggleActivationStillConsumesKeyShortcutReleaseWithoutEmittingIt() throws {
        let dictate = GlobalShortcut(keyCode: 8, modifiers: [.maskCommand], keyLabel: "C")
        let context = makeContext(dictate: dictate, dictateActivation: .toggle)
        let down = try makeEvent(keyCode: 8, flags: .maskCommand, targetProcessIdentifier: 21)
        let up = try makeEvent(keyCode: 8, flags: .maskCommand)

        XCTAssertEqual(
            context.process(down, type: .keyDown),
            HotkeyEventOutcome(action: .press(21), consumesEvent: true)
        )
        XCTAssertEqual(
            context.process(up, type: .keyUp),
            HotkeyEventOutcome(action: nil, consumesEvent: true)
        )
        XCTAssertEqual(
            context.process(down, type: .keyDown),
            HotkeyEventOutcome(action: .press(21), consumesEvent: true)
        )
    }

    func testSwitchingActivationModeWhileHeldDoesNotStrandTheNextPress() throws {
        let context = makeContext()
        let down = try makeEvent(flags: .maskSecondaryFn)
        let up = try makeEvent(flags: [])
        XCTAssertEqual(context.process(down, type: .flagsChanged).action, .press(nil))

        context.configure(
            dictate: .dictate,
            dictateActivation: .toggle,
            pasteLatest: .pasteLatest,
            openClipboard: .openClipboard
        )

        XCTAssertEqual(context.process(up, type: .flagsChanged), .ignored)
        XCTAssertEqual(context.process(down, type: .flagsChanged).action, .press(nil))
    }

    func testScreenAwareModifierChordEmitsOnePressAndRelease() throws {
        let context = makeContext()
        let down = try makeEvent(flags: [.maskControl, .maskAlternate], targetProcessIdentifier: 84)
        let up = try makeEvent(flags: [.maskControl])

        XCTAssertEqual(
            context.process(down, type: .flagsChanged),
            HotkeyEventOutcome(action: .screenAwarePress(84), consumesEvent: false)
        )
        XCTAssertEqual(context.process(down, type: .flagsChanged), .ignored)
        XCTAssertEqual(
            context.process(up, type: .flagsChanged),
            HotkeyEventOutcome(action: .screenAwareRelease, consumesEvent: false)
        )
    }

    func testKeyShortcutConsumesInitialPressAutorepeatAndRelease() throws {
        let dictate = GlobalShortcut(
            keyCode: 8,
            modifiers: [.maskCommand, .maskControl],
            keyLabel: "C"
        )
        let context = makeContext(dictate: dictate)
        let down = try makeEvent(
            keyCode: 8,
            flags: [.maskCommand, .maskControl],
            targetProcessIdentifier: 21
        )
        let repeatEvent = try makeEvent(
            keyCode: 8,
            flags: [.maskCommand, .maskControl],
            autorepeat: true
        )
        let up = try makeEvent(keyCode: 8, flags: [.maskCommand, .maskControl])

        XCTAssertEqual(
            context.process(down, type: .keyDown),
            HotkeyEventOutcome(action: .press(21), consumesEvent: true)
        )
        XCTAssertEqual(
            context.process(repeatEvent, type: .keyDown),
            HotkeyEventOutcome(action: nil, consumesEvent: true)
        )
        XCTAssertEqual(
            context.process(up, type: .keyUp),
            HotkeyEventOutcome(action: .release, consumesEvent: true)
        )
    }

    func testClipboardShortcutsEmitActionsAndConsumeKeyDown() throws {
        let context = makeContext()
        let paste = try makeEvent(keyCode: 9, flags: [.maskCommand, .maskAlternate])
        let clipboard = try makeEvent(
            keyCode: 9,
            flags: [.maskCommand, .maskAlternate, .maskShift]
        )

        XCTAssertEqual(
            context.process(paste, type: .keyDown),
            HotkeyEventOutcome(action: .pasteLatest, consumesEvent: true)
        )
        XCTAssertEqual(
            context.process(clipboard, type: .keyDown),
            HotkeyEventOutcome(action: .openClipboard, consumesEvent: true)
        )
    }

    private func makeContext(
        dictate: GlobalShortcut = .dictate,
        dictateActivation: HotkeyActivationMode = .hold
    ) -> HotkeyEventTapContext {
        HotkeyEventTapContext(
            dictate: dictate,
            dictateActivation: dictateActivation,
            pasteLatest: .pasteLatest,
            openClipboard: .openClipboard,
            onAction: { _ in }
        )
    }

    private func makeEvent(
        keyCode: CGKeyCode = 0,
        flags: CGEventFlags,
        autorepeat: Bool = false,
        targetProcessIdentifier: pid_t? = nil
    ) throws -> CGEvent {
        let event = try XCTUnwrap(
            CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)
        )
        event.flags = flags
        event.setIntegerValueField(.keyboardEventAutorepeat, value: autorepeat ? 1 : 0)
        if let targetProcessIdentifier {
            event.setIntegerValueField(
                .eventTargetUnixProcessID,
                value: Int64(targetProcessIdentifier)
            )
        }
        return event
    }
}
