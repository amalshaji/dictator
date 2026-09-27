import XCTest
@testable import DictatorCore

final class StyleResolverTests: XCTestCase {
    private let formal = WritingStyle(name: "Formal email", instruction: "Write formally.")
    private let casual = WritingStyle(name: "Casual chat", instruction: "Keep it casual.")

    func testSelectedStyleIsUsed() {
        let instruction = StyleResolver.instruction(
            styles: [formal, casual],
            globalStyleID: casual.id
        )
        XCTAssertEqual(instruction, "Keep it casual.")
    }

    func testDisabledSelectedStyleReturnsNil() {
        var disabledFormal = formal
        disabledFormal.isEnabled = false
        let instruction = StyleResolver.instruction(
            styles: [disabledFormal],
            globalStyleID: disabledFormal.id
        )
        XCTAssertNil(instruction)
    }

    func testDeletedSelectedStyleReturnsNil() {
        let instruction = StyleResolver.instruction(
            styles: [casual],
            globalStyleID: UUID()
        )
        XCTAssertNil(instruction)
    }

    func testNoSelectedStyleReturnsNil() {
        let instruction = StyleResolver.instruction(
            styles: [formal, casual],
            globalStyleID: nil
        )
        XCTAssertNil(instruction)
    }

    func testPersistedDataDecodesLegacyPayloadWithUnknownKey() throws {
        let legacyJSON = """
        {"styles":[],"someRetiredField":{"com.apple.mail":"\(formal.id.uuidString)"}}
        """
        let decoded = try JSONDecoder().decode(PersistedData.self, from: Data(legacyJSON.utf8))
        XCTAssertTrue(decoded.styles.isEmpty)
    }
}
