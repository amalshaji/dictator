import XCTest
@testable import DictatorCore

final class StyleResolverTests: XCTestCase {
    private let formal = WritingStyle(name: "Formal email", instruction: "Write formally.")
    private let casual = WritingStyle(name: "Casual chat", instruction: "Keep it casual.")

    func testPerAppOverrideWinsOverGlobalStyle() {
        let instruction = StyleResolver.instruction(
            forApp: "com.apple.mail",
            overrides: ["com.apple.mail": formal.id],
            styles: [formal, casual],
            globalStyleID: casual.id
        )
        XCTAssertEqual(instruction, "Write formally.")
    }

    func testUnmappedAppFallsBackToGlobalStyle() {
        let instruction = StyleResolver.instruction(
            forApp: "com.tinyspeck.slackmacgap",
            overrides: ["com.apple.mail": formal.id],
            styles: [formal, casual],
            globalStyleID: casual.id
        )
        XCTAssertEqual(instruction, "Keep it casual.")
    }

    func testNilBundleIDUsesGlobalStyle() {
        let instruction = StyleResolver.instruction(
            forApp: nil,
            overrides: ["com.apple.mail": formal.id],
            styles: [formal, casual],
            globalStyleID: casual.id
        )
        XCTAssertEqual(instruction, "Keep it casual.")
    }

    func testDisabledOverrideStyleFallsBackToGlobalStyle() {
        var disabledFormal = formal
        disabledFormal.isEnabled = false
        let instruction = StyleResolver.instruction(
            forApp: "com.apple.mail",
            overrides: ["com.apple.mail": disabledFormal.id],
            styles: [disabledFormal, casual],
            globalStyleID: casual.id
        )
        XCTAssertEqual(instruction, "Keep it casual.")
    }

    func testDeletedOverrideStyleFallsBackToGlobalStyle() {
        let instruction = StyleResolver.instruction(
            forApp: "com.apple.mail",
            overrides: ["com.apple.mail": UUID()],
            styles: [casual],
            globalStyleID: casual.id
        )
        XCTAssertEqual(instruction, "Keep it casual.")
    }

    func testNoGlobalStyleAndNoOverrideReturnsNil() {
        let instruction = StyleResolver.instruction(
            forApp: "com.apple.mail",
            overrides: [:],
            styles: [formal, casual],
            globalStyleID: nil
        )
        XCTAssertNil(instruction)
    }

    func testPersistedDataRoundTripsAppStyleOverrides() throws {
        let data = PersistedData(styles: [formal], appStyleOverrides: ["com.apple.mail": formal.id])
        let encoded = try JSONEncoder().encode(data)
        let decoded = try JSONDecoder().decode(PersistedData.self, from: encoded)
        XCTAssertEqual(decoded.appStyleOverrides, ["com.apple.mail": formal.id])
    }

    func testPersistedDataDecodesLegacyPayloadWithoutOverrides() throws {
        let decoded = try JSONDecoder().decode(PersistedData.self, from: Data("{}".utf8))
        XCTAssertTrue(decoded.appStyleOverrides.isEmpty)
    }
}
