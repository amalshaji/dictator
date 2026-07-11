import XCTest
@testable import DictatorCore

final class PersonalizationTests: XCTestCase {
    func testValidationNormalizesAndRejectsVocabularyCollisions() throws {
        let existing = VocabularyEntry(value: "Dictator", variants: ["dictater"])
        var candidate = VocabularyEntry(value: "  OpenDrop  ", variants: [" open drop ", "OPEN DROP", ""])
        candidate = try PersonalizationValidator.validateVocabulary(candidate, among: [existing])
        XCTAssertEqual(candidate.value, "OpenDrop")
        XCTAssertEqual(candidate.variants, ["open drop"])
        XCTAssertThrowsError(try PersonalizationValidator.validateVocabulary(.init(value: "Dictater"), among: [existing]))
    }

    func testValidationRejectsDuplicateStyleAndSnippet() {
        XCTAssertThrowsError(try PersonalizationValidator.validateStyle(.init(name: "Email", instruction: "Brief"), among: [.init(name: "email", instruction: "Warm")]))
        XCTAssertThrowsError(try PersonalizationValidator.validateSnippet(.init(trigger: "Signature", expansion: "B"), among: [.init(trigger: "signature", expansion: "A")]))
    }

    func testSnippetExpanderUsesWholePhrasesAndLongestTriggerFirst() {
        let snippets = [
            SnippetEntry(trigger: "my email", expansion: "amal@example.com"),
            SnippetEntry(trigger: "email", expansion: "wrong")
        ]
        XCTAssertEqual(SnippetExpander.expand("Send it to my email.", snippets: snippets), "Send it to amal@example.com.")
        XCTAssertEqual(SnippetExpander.expand("The emailer called.", snippets: snippets), "The emailer called.")
    }

    func testVocabularyNormalizerUsesWholeWordsAndLongestTermsFirst() {
        let entries = [
            VocabularyEntry(value: "PostgreSQL", variants: ["post gress", "postgres"]),
            VocabularyEntry(value: "Dictator", variants: ["dictater"])
        ]
        XCTAssertEqual(VocabularyNormalizer.normalize("Use post gress in dictater.", vocabulary: entries), "Use PostgreSQL in Dictator.")
    }
}
