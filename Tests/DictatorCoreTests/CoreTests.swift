import XCTest
@testable import DictatorCore

final class CoreTests: XCTestCase {
    func testSnippetExpanderUsesWholePhrasesAndLongestTriggerFirst() {
        let snippets = [
            SnippetEntry(trigger: "my email", expansion: "amal@example.com"),
            SnippetEntry(trigger: "email", expansion: "wrong")
        ]
        XCTAssertEqual(SnippetExpander.expand("Send it to my email.", snippets: snippets), "Send it to amal@example.com.")
        XCTAssertEqual(SnippetExpander.expand("The emailer called.", snippets: snippets), "The emailer called.")
    }
    func testWAVEncoderBuildsValidHeader() {
        let pcm = Data([0, 0, 255, 127, 0, 128])
        let wav = WAVEncoder.encodePCM16(pcm)
        XCTAssertEqual(String(data: wav[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: wav[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: wav[36..<40], encoding: .ascii), "data")
        XCTAssertEqual(wav.count, 44 + pcm.count)
    }

    func testVocabularyNormalizerUsesWholeWordsAndLongestTermsFirst() {
        let entries = [
            VocabularyEntry(value: "PostgreSQL", variants: ["post gress", "postgres"]),
            VocabularyEntry(value: "Dictator", variants: ["dictater"])
        ]
        XCTAssertEqual(
            VocabularyNormalizer.normalize("Use post gress in dictater.", vocabulary: entries),
            "Use PostgreSQL in Dictator."
        )
    }

    func testCleanupValidatorProtectsURLsEmailNumbersAndVocabulary() throws {
        let raw = "Um email me at a@example.com about Dictator version 2.4 at https://example.com."
        let valid = "Email me at a@example.com about Dictator version 2.4 at https://example.com."
        XCTAssertNoThrow(try CleanupSafetyValidator.validate(raw: raw, cleaned: valid, vocabulary: [.init(value: "Dictator")]))
        XCTAssertThrowsError(try CleanupSafetyValidator.validate(raw: raw, cleaned: "Email me about version 3.", vocabulary: [.init(value: "Dictator")]))
    }

    func testCleanupValidatorRejectsLargeMeaningChangingExpansion() {
        XCTAssertThrowsError(try CleanupSafetyValidator.validate(raw: "Hello there", cleaned: String(repeating: "This adds information. ", count: 20), vocabulary: []))
    }

    func testPricingCatalogUsesAudioDuration() {
        XCTAssertEqual(PricingCatalog.estimatedSTTCost(provider: .groq, model: "whisper-large-v3-turbo", audioSeconds: 3_600), Decimal(string: "0.04"))
        XCTAssertEqual(PricingCatalog.estimatedSTTCost(provider: .xAI, model: "grok-transcribe", audioSeconds: 1_800), Decimal(string: "0.05"))
    }

    func testRegistriesExposeAllPlannedProviders() {
        XCTAssertEqual(Set(ProviderRegistry.sttMetadata.map(\.kind)), Set([.groq, .cloudflare, .xAI, .deepgram, .assemblyAI, .gladia]))
        XCTAssertEqual(Set(CleanupProviderRegistry.metadata.map(\.kind)), Set([.groq, .cloudflare, .gemini, .xAI, .openRouter, .openAICompatible]))
    }
}
