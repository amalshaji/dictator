import XCTest
@testable import DictatorCore

final class CleanupProcessingTests: XCTestCase {
    func testValidatorProtectsURLsEmailNumbersAndVocabulary() throws {
        let raw = "Um email me at a@example.com about Dictator version 2.4 at https://example.com."
        let valid = "Email me at a@example.com about Dictator version 2.4 at https://example.com."
        XCTAssertNoThrow(try CleanupSafetyValidator.validate(raw: raw, cleaned: valid, vocabulary: [.init(value: "Dictator")]))
        XCTAssertThrowsError(try CleanupSafetyValidator.validate(raw: raw, cleaned: "Email me about version 3.", vocabulary: [.init(value: "Dictator")]))
    }

    func testValidatorRejectsLargeMeaningChangingExpansion() {
        XCTAssertThrowsError(try CleanupSafetyValidator.validate(raw: "Hello there", cleaned: String(repeating: "This adds information. ", count: 20), vocabulary: []))
    }

    func testValidatorPreservesRepeatedProtectedTokens() {
        XCTAssertThrowsError(try CleanupSafetyValidator.validate(raw: "Use port 8080, then retry port 8080.", cleaned: "Use port 8080, then retry.", vocabulary: []))
    }

    func testPromptRoutesSelectionEditsWithoutInventingCheckboxes() throws {
        let prompt = CleanupPrompt.system(vocabulary: [])
        XCTAssertTrue(prompt.contains("transcription"))
        XCTAssertTrue(prompt.contains("transformation"))
        XCTAssertFalse(prompt.contains("- [ ]"))

        let user = try CleanupPrompt.user(
            request: CleanupRequest(input: .contextual(spokenText: "make it lowercase", selectedText: "HELLO WORLD"))
        )
        XCTAssertTrue(user.contains("make it lowercase"))
        XCTAssertTrue(user.contains("HELLO WORLD"))
    }

    func testTranscriptProcessorReturnsCleanedTextAndMetadata() async {
        let result = await TranscriptProcessor().process(
            rawText: "first sentence second sentence",
            vocabulary: [],
            snippets: [],
            cleanup: .init(provider: FormattingCleanupProvider(), model: "formatting-model", credentials: .init(apiKey: "shared-key"))
        )
        guard case .cleaned(let cleanupResult) = result else {
            return XCTFail("Expected cleaned transcript")
        }
        XCTAssertEqual(cleanupResult.output, .transcription("First sentence. Second sentence."))
        XCTAssertEqual(cleanupResult.provider, .groq)
        XCTAssertEqual(cleanupResult.model, "formatting-model")
    }

    func testTranscriptProcessorPassesSelectedTextForTransformation() async {
        let result = await TranscriptProcessor().process(
            rawText: "make it lowercase",
            selectedText: "HELLO WORLD",
            vocabulary: [],
            snippets: [],
            cleanup: .init(provider: SelectionTransformingCleanupProvider(), model: "transforming-model", credentials: .init(apiKey: "shared-key"))
        )
        guard case .cleaned(let cleanupResult) = result else {
            return XCTFail("Expected transformed selection")
        }
        XCTAssertEqual(cleanupResult.output, .transformation("hello world"))
    }

    func testCleanupFailureDoesNotReplaceSelectionWithSpokenCommand() async {
        let result = await TranscriptProcessor().process(
            rawText: "make it lowercase",
            selectedText: "HELLO WORLD",
            vocabulary: [],
            snippets: [],
            cleanup: .init(provider: FailingCleanupProvider(), model: "failing-model", credentials: .init(apiKey: "shared-key"))
        )
        guard case .failed(let reason) = result else {
            return XCTFail("Selection cleanup failure must stop processing")
        }
        XCTAssertEqual(reason, "The provider returned an invalid response.")
    }

    func testCleanupFailureWithoutSelectionFallsBackToTranscript() async {
        let result = await TranscriptProcessor().process(
            rawText: "ordinary dictation",
            vocabulary: [],
            snippets: [],
            cleanup: .init(provider: FailingCleanupProvider(), model: "failing-model", credentials: .init(apiKey: "shared-key"))
        )
        guard case .fallback(let text, let reason) = result else {
            return XCTFail("Ordinary dictation should retain its raw fallback")
        }
        XCTAssertEqual(text, "ordinary dictation")
        XCTAssertEqual(reason, "The provider returned an invalid response.")
    }

    func testOversizedSelectionIsNotSentOrReplaced() async {
        let result = await TranscriptProcessor().process(
            rawText: "make it lowercase",
            selectedText: String(repeating: "A", count: 20_001),
            vocabulary: [],
            snippets: [],
            cleanup: .init(provider: SelectionTransformingCleanupProvider(), model: "transforming-model", credentials: .init(apiKey: "shared-key"))
        )
        guard case .failed(let reason) = result else {
            return XCTFail("Oversized selection must stop processing")
        }
        XCTAssertEqual(reason, "Cleanup output was rejected: selected text is too long")
    }

    func testResponseDecoderRejectsTransformationWithoutSelection() {
        let response = #"{"intent":"transformation","text":"hello"}"#
        XCTAssertThrowsError(try CleanupResponseDecoder.decode(response, for: .init(input: .transcription("make it lowercase")))) { error in
            XCTAssertEqual(error as? ProviderError, .cleanupRejected("transformation requires selected text"))
        }
    }

    func testResponseDecoderRejectsTransformationWithEmptySelection() {
        let response = #"{"intent":"transformation","text":"hello"}"#
        XCTAssertThrowsError(try CleanupResponseDecoder.decode(response, for: .init(input: .contextual(spokenText: "make it lowercase", selectedText: "")))) { error in
            XCTAssertEqual(error as? ProviderError, .cleanupRejected("transformation requires selected text"))
        }
    }
}

private struct FormattingCleanupProvider: CleanupLLMProvider {
    let metadata = ProviderMetadata(kind: .groq, displayName: "Formatting", defaultModel: "formatting-model", models: ["formatting-model"], requiresAccountID: false)
    func validate(credentials: ProviderCredentials) async throws {}
    func listModels(credentials: ProviderCredentials) async throws -> [String] { metadata.models }
    func clean(request: CleanupRequest, model: String, credentials: ProviderCredentials) async throws -> CleanupResult {
        CleanupResult(output: .transcription("First sentence. Second sentence."), provider: metadata.kind, model: model, latency: 0)
    }
}

private struct SelectionTransformingCleanupProvider: CleanupLLMProvider {
    let metadata = ProviderMetadata(kind: .groq, displayName: "Transforming", defaultModel: "transforming-model", models: ["transforming-model"], requiresAccountID: false)
    func validate(credentials: ProviderCredentials) async throws {}
    func listModels(credentials: ProviderCredentials) async throws -> [String] { metadata.models }
    func clean(request: CleanupRequest, model: String, credentials: ProviderCredentials) async throws -> CleanupResult {
        guard case .contextual(_, let selectedText) = request.input else { throw ProviderError.invalidResponse }
        return CleanupResult(output: .transformation(selectedText.lowercased()), provider: metadata.kind, model: model, latency: 0)
    }
}

private struct FailingCleanupProvider: CleanupLLMProvider {
    let metadata = ProviderMetadata(kind: .groq, displayName: "Failing", defaultModel: "failing-model", models: ["failing-model"], requiresAccountID: false)
    func validate(credentials: ProviderCredentials) async throws {}
    func listModels(credentials: ProviderCredentials) async throws -> [String] { metadata.models }
    func clean(request: CleanupRequest, model: String, credentials: ProviderCredentials) async throws -> CleanupResult {
        throw ProviderError.invalidResponse
    }
}
