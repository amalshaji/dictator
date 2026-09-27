import XCTest
@testable import Dictator

final class ConnectionTestStateTests: XCTestCase {
    func testIdleLabelPromptsToStartATest() {
        XCTAssertEqual(ConnectionTestState.idle.label, "Test connection")
        XCTAssertNil(ConnectionTestState.idle.glyph)
    }

    func testTestingLabelHasNoGlyphSinceItShowsAProgressViewInstead() {
        XCTAssertEqual(ConnectionTestState.testing.label, "Testing…")
        XCTAssertNil(ConnectionTestState.testing.glyph)
    }

    func testConnectedLabelUsesASuccessCheckmark() {
        XCTAssertEqual(ConnectionTestState.connected.label, "Connected")
        XCTAssertEqual(ConnectionTestState.connected.glyph, "checkmark.circle.fill")
    }

    func testFailedLabelSurfacesTheErrorMessageWithAWarningGlyph() {
        let state = ConnectionTestState.failed("Invalid API key")
        XCTAssertEqual(state.label, "Invalid API key")
        XCTAssertEqual(state.glyph, "exclamationmark.triangle.fill")
    }
}
