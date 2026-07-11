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

    func testCleanupValidatorPreservesRepeatedProtectedTokens() {
        XCTAssertThrowsError(
            try CleanupSafetyValidator.validate(
                raw: "Use port 8080, then retry port 8080.",
                cleaned: "Use port 8080, then retry.",
                vocabulary: []
            )
        )
    }

    func testCleanupPromptRoutesSelectionEditsWithoutInventingCheckboxes() throws {
        let prompt = CleanupPrompt.system(vocabulary: [])

        XCTAssertTrue(prompt.contains("transcription"))
        XCTAssertTrue(prompt.contains("transformation"))
        XCTAssertFalse(prompt.contains("- [ ]"))

        let user = try CleanupPrompt.user(
            request: CleanupRequest(
                transcript: "make it lowercase",
                selectedText: "HELLO WORLD"
            )
        )
        XCTAssertTrue(user.contains("make it lowercase"))
        XCTAssertTrue(user.contains("HELLO WORLD"))
    }

    func testTranscriptProcessorReturnsCleanedTextAndMetadata() async {
        let processor = TranscriptProcessor()
        let cleanup = TranscriptCleanupConfiguration(
            provider: FormattingCleanupProvider(),
            model: "formatting-model",
            credentials: ProviderCredentials(apiKey: "shared-key")
        )

        let result = await processor.process(
            rawText: "first sentence second sentence",
            vocabulary: [],
            snippets: [],
            cleanup: cleanup
        )

        XCTAssertEqual(result.finalText, "First sentence. Second sentence.")
        XCTAssertEqual(result.cleanupResult?.provider, .groq)
        XCTAssertEqual(result.cleanupResult?.model, "formatting-model")
    }

    func testTranscriptProcessorPassesSelectedTextForTransformation() async {
        let cleanup = TranscriptCleanupConfiguration(
            provider: SelectionTransformingCleanupProvider(),
            model: "transforming-model",
            credentials: ProviderCredentials(apiKey: "shared-key")
        )

        let result = await TranscriptProcessor().process(
            rawText: "make it lowercase",
            selectedText: "HELLO WORLD",
            vocabulary: [],
            snippets: [],
            cleanup: cleanup
        )

        XCTAssertEqual(result.finalText, "hello world")
        XCTAssertEqual(result.cleanupResult?.intent, .transformation)
    }

    func testCleanupFailureDoesNotReplaceSelectionWithSpokenCommand() async {
        let cleanup = TranscriptCleanupConfiguration(
            provider: FailingCleanupProvider(),
            model: "failing-model",
            credentials: ProviderCredentials(apiKey: "shared-key")
        )

        let result = await TranscriptProcessor().process(
            rawText: "make it lowercase",
            selectedText: "HELLO WORLD",
            vocabulary: [],
            snippets: [],
            cleanup: cleanup
        )

        XCTAssertEqual(result.finalText, "HELLO WORLD")
        XCTAssertNotNil(result.cleanupFallbackReason)
    }

    func testOversizedSelectionIsNotSentOrReplaced() async {
        let selectedText = String(repeating: "A", count: 20_001)
        let cleanup = TranscriptCleanupConfiguration(
            provider: SelectionTransformingCleanupProvider(),
            model: "transforming-model",
            credentials: ProviderCredentials(apiKey: "shared-key")
        )

        let result = await TranscriptProcessor().process(
            rawText: "make it lowercase",
            selectedText: selectedText,
            vocabulary: [],
            snippets: [],
            cleanup: cleanup
        )

        XCTAssertEqual(result.finalText, selectedText)
        XCTAssertEqual(result.cleanupFallbackReason, "Cleanup output was rejected: selected text is too long")
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

private struct FormattingCleanupProvider: CleanupLLMProvider {
    let metadata = ProviderMetadata(
        kind: .groq,
        displayName: "Formatting",
        defaultModel: "formatting-model",
        models: ["formatting-model"],
        requiresAccountID: false
    )

    func validate(credentials: ProviderCredentials) async throws {}
    func listModels(credentials: ProviderCredentials) async throws -> [String] { metadata.models }
    func clean(request: CleanupRequest, model: String, credentials: ProviderCredentials) async throws -> CleanupResult {
        CleanupResult(
            text: "First sentence. Second sentence.",
            provider: metadata.kind,
            model: model,
            latency: 0
        )
    }
}

private struct SelectionTransformingCleanupProvider: CleanupLLMProvider {
    let metadata = ProviderMetadata(
        kind: .groq,
        displayName: "Transforming",
        defaultModel: "transforming-model",
        models: ["transforming-model"],
        requiresAccountID: false
    )

    func validate(credentials: ProviderCredentials) async throws {}
    func listModels(credentials: ProviderCredentials) async throws -> [String] { metadata.models }
    func clean(request: CleanupRequest, model: String, credentials: ProviderCredentials) async throws -> CleanupResult {
        CleanupResult(
            text: request.selectedText?.lowercased() ?? request.transcript,
            intent: .transformation,
            provider: metadata.kind,
            model: model,
            latency: 0
        )
    }
}

private struct FailingCleanupProvider: CleanupLLMProvider {
    let metadata = ProviderMetadata(
        kind: .groq,
        displayName: "Failing",
        defaultModel: "failing-model",
        models: ["failing-model"],
        requiresAccountID: false
    )

    func validate(credentials: ProviderCredentials) async throws {}
    func listModels(credentials: ProviderCredentials) async throws -> [String] { metadata.models }
    func clean(request: CleanupRequest, model: String, credentials: ProviderCredentials) async throws -> CleanupResult {
        throw ProviderError.invalidResponse
    }
}
