import XCTest
@testable import DictatorCore

final class CleanupProcessingTests: XCTestCase {
    func testValidatorAllowsSemanticRewriteThatDropsRetractedSpeech() {
        let raw = "Um so we should meet on Tuesday at 3. Actually no, scratch that, let's do Wednesday at 4."
        XCTAssertNoThrow(try CleanupSafetyValidator.validate(raw: raw, cleaned: "Let's meet on Wednesday at 4."))
    }

    func testValidatorAllowsListFormattingOfShortDictation() {
        XCTAssertNoThrow(try CleanupSafetyValidator.validate(raw: "milk eggs bread", cleaned: "- Milk\n- Eggs\n- Bread"))
    }

    func testValidatorRejectsEmptyFencedAndRunawayOutput() {
        XCTAssertThrowsError(try CleanupSafetyValidator.validate(raw: "Hello there", cleaned: "  "))
        XCTAssertThrowsError(try CleanupSafetyValidator.validate(raw: "Hello there", cleaned: "```\nHello there\n```"))
        XCTAssertThrowsError(try CleanupSafetyValidator.validate(raw: "Hello there", cleaned: String(repeating: "This adds information. ", count: 20)))
    }

    func testResponseDecoderAcceptsFormattedRewriteAndIgnoresUnknownFields() throws {
        let raw = "Hey team, so, um, for the launch we need to finish the landing page, uh, review pricing, oh and set up analytics."
        let text = "Hey team, for the launch we need to:\n\n- Finish the landing page\n- Review pricing\n- Set up analytics"
        let response = try responseJSON(["intent": "transcription", "text": text, "withdrawnSpans": []])

        XCTAssertEqual(try CleanupResponseDecoder.decode(response, for: .init(input: .transcription(raw))), .transcription(text))
    }

    func testPromptRoutesSelectionEditsWithoutInventingCheckboxes() throws {
        let prompt = CleanupPrompt.system(request: .init(input: .transcription("hello")))
        XCTAssertTrue(prompt.contains("transcription"))
        XCTAssertTrue(prompt.contains("transformation"))
        XCTAssertFalse(prompt.contains("- [ ]"))

        let user = try CleanupPrompt.user(
            request: CleanupRequest(input: .contextual(spokenText: "make it lowercase", selectedText: "HELLO WORLD"))
        )
        XCTAssertTrue(user.contains("make it lowercase"))
        XCTAssertTrue(user.contains("HELLO WORLD"))
    }

    func testPromptAsksForSemanticRetractionsListsAndParagraphs() {
        let prompt = CleanupPrompt.system(request: .init(input: .transcription("hello")))

        XCTAssertTrue(prompt.contains("scratch that"))
        XCTAssertTrue(prompt.contains("keep only their final intent"))
        XCTAssertTrue(prompt.contains("Remove filler"))
        XCTAssertTrue(prompt.contains("always become a list"))
        XCTAssertTrue(prompt.contains("new paragraph"))
        XCTAssertTrue(prompt.contains("Never answer questions"))
        XCTAssertFalse(prompt.contains("UTF16"))
    }

    func testPromptListsVocabularyWithKnownMishearingsForSemanticReplacement() {
        let prompt = CleanupPrompt.system(request: .init(
            input: .transcription("hello"),
            vocabulary: [
                .init(value: "PostgreSQL", variants: ["post gress"]),
                .init(value: "Kubernetes"),
                .init(value: "Disabled", isEnabled: false)
            ]
        ))
        XCTAssertTrue(prompt.contains(#"- PostgreSQL (often misheard as "post gress")"#))
        XCTAssertTrue(prompt.contains("- Kubernetes\n"))
        XCTAssertTrue(prompt.contains("context shows the speaker meant it"))
        XCTAssertFalse(prompt.contains("Disabled"))
    }

    func testCleanupReceivesUnnormalizedTextSoLLMAppliesVocabulary() async {
        let vocabulary = [VocabularyEntry(value: "Dictator", variants: ["dictater"])]
        let provider = EchoCleanupProvider()
        let cleaned = await TranscriptProcessor().process(
            rawText: "the dictater app",
            vocabulary: vocabulary,
            snippets: [],
            cleanup: .init(provider: provider, model: "echo", credentials: .init(apiKey: "key"))
        )
        guard case .cleaned(let result) = cleaned else { return XCTFail("Expected cleaned transcript") }
        XCTAssertEqual(result.output, .transcription("the dictater app"))

        let raw = await TranscriptProcessor().process(rawText: "the dictater app", vocabulary: vocabulary, snippets: [], cleanup: nil)
        XCTAssertEqual(raw, .raw("the Dictator app"), "Without cleanup the literal variant replacement still applies")
    }

    func testPromptIncludesCustomInstructionForTranscriptionOnly() {
        let input = CleanupInput.transcription("hello")
        let prompt = CleanupPrompt.system(request: .init(input: input, customInstruction: "Prefer British spelling"))
        XCTAssertTrue(prompt.contains("Prefer British spelling"))
        XCTAssertTrue(prompt.contains("never change meaning"))

        XCTAssertFalse(CleanupPrompt.system(request: .init(input: input, customInstruction: "   ")).contains("user preferences"))
        XCTAssertFalse(CleanupPrompt.system(request: .init(input: input)).contains("user preferences"))
    }

    func testPromptAppliesCustomInstructionAfterStyle() throws {
        let prompt = CleanupPrompt.system(request: .init(
            input: .transcription("hello"),
            styleInstruction: "Use US spelling",
            customInstruction: "Prefer British spelling"
        ))
        let styleIndex = try XCTUnwrap(prompt.range(of: "Use US spelling")).lowerBound
        let customIndex = try XCTUnwrap(prompt.range(of: "Prefer British spelling")).lowerBound
        XCTAssertLessThan(styleIndex, customIndex, "Custom instruction must follow the style so it takes precedence")
        XCTAssertTrue(prompt.contains("They override the writing style when the two conflict"))
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

    private func responseJSON(_ payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}

private struct FormattingCleanupProvider: CleanupLLMProvider {
    let metadata = ProviderMetadata(kind: .groq, displayName: "Formatting", defaultModel: "formatting-model", models: ["formatting-model"])
    func validate(credentials: ProviderCredentials) async throws {}
    func listModels(credentials: ProviderCredentials) async throws -> [String] { metadata.models }
    func clean(request: CleanupRequest, model: String, credentials: ProviderCredentials) async throws -> CleanupResult {
        CleanupResult(output: .transcription("First sentence. Second sentence."), provider: metadata.kind, model: model, latency: 0)
    }
}

private struct SelectionTransformingCleanupProvider: CleanupLLMProvider {
    let metadata = ProviderMetadata(kind: .groq, displayName: "Transforming", defaultModel: "transforming-model", models: ["transforming-model"])
    func validate(credentials: ProviderCredentials) async throws {}
    func listModels(credentials: ProviderCredentials) async throws -> [String] { metadata.models }
    func clean(request: CleanupRequest, model: String, credentials: ProviderCredentials) async throws -> CleanupResult {
        guard case .contextual(_, let selectedText) = request.input else { throw ProviderError.invalidResponse }
        return CleanupResult(output: .transformation(selectedText.lowercased()), provider: metadata.kind, model: model, latency: 0)
    }
}

private struct EchoCleanupProvider: CleanupLLMProvider {
    let metadata = ProviderMetadata(kind: .groq, displayName: "Echo", defaultModel: "echo", models: ["echo"])
    func validate(credentials: ProviderCredentials) async throws {}
    func listModels(credentials: ProviderCredentials) async throws -> [String] { metadata.models }
    func clean(request: CleanupRequest, model: String, credentials: ProviderCredentials) async throws -> CleanupResult {
        CleanupResult(output: .transcription(request.input.spokenText), provider: metadata.kind, model: model, latency: 0)
    }
}

private struct FailingCleanupProvider: CleanupLLMProvider {
    let metadata = ProviderMetadata(kind: .groq, displayName: "Failing", defaultModel: "failing-model", models: ["failing-model"])
    func validate(credentials: ProviderCredentials) async throws {}
    func listModels(credentials: ProviderCredentials) async throws -> [String] { metadata.models }
    func clean(request: CleanupRequest, model: String, credentials: ProviderCredentials) async throws -> CleanupResult {
        throw ProviderError.invalidResponse
    }
}
