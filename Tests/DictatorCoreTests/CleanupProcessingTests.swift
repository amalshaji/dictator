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

    func testValidatorAllowsDeduplicatingRepeatedVocabularyTerm() {
        XCTAssertNoThrow(try CleanupSafetyValidator.validate(raw: "Dictator Dictator", cleaned: "Dictator", vocabulary: [.init(value: "Dictator")]))
    }

    func testResponseDecoderAllowsVerifiedMultiSentenceRetraction() throws {
        let withdrawn = "I want to name my child XYZ, or maybe just YZ. I think my wife would love YZ, but I am going with XYZ."
        let raw = "\(withdrawn) I retract all of that. I'll just name my child YZ."
        let response = try transcriptionResponse(
            text: "I'll just name my child YZ.",
            raw: raw,
            withdrawnRanges: [(raw as NSString).range(of: withdrawn)]
        )

        let output = try CleanupResponseDecoder.decode(response, for: .init(input: .transcription(raw)))

        XCTAssertEqual(output, .transcription("I'll just name my child YZ."))
    }

    func testVerifiedRetractionExemptsOnlyProtectedValuesInsideItsSpan() throws {
        let retained = "Keep owner@example.com, https://keep.example/path, 42, `keepCode`, and Dictator."
        let withdrawn = " Send LegacyTool 17 to old@example.com at https://old.example/path using `legacyCode`."
        let raw = "\(retained)\(withdrawn) I take back that instruction. Finalize it."
        let range = (raw as NSString).range(of: withdrawn)
        let vocabulary = [VocabularyEntry(value: "Dictator"), VocabularyEntry(value: "LegacyTool")]
        let valid = "\(retained) Finalize it."

        let response = try transcriptionResponse(text: valid, raw: raw, withdrawnRanges: [range])
        let output = try CleanupResponseDecoder.decode(
            response,
            for: .init(input: .transcription(raw), vocabulary: vocabulary)
        )
        XCTAssertEqual(output, .transcription(valid))

        let unsafeOutputs = [
            valid.replacingOccurrences(of: "owner@example.com", with: "other@example.com"),
            valid.replacingOccurrences(of: "https://keep.example/path", with: "https://other.example/path"),
            valid.replacingOccurrences(of: "42", with: "43"),
            valid.replacingOccurrences(of: "`keepCode`", with: "`otherCode`"),
            valid.replacingOccurrences(of: "Dictator", with: "Dictation")
        ]
        for unsafe in unsafeOutputs {
            let unsafeResponse = try transcriptionResponse(text: unsafe, raw: raw, withdrawnRanges: [range])
            XCTAssertThrowsError(
                try CleanupResponseDecoder.decode(
                    unsafeResponse,
                    for: .init(input: .transcription(raw), vocabulary: vocabulary)
                )
            )
        }
    }

    func testResponseDecoderRejectsMalformedUnverifiedAndOverlappingWithdrawnSpans() throws {
        let raw = "Remove 17. I take back that instruction. Keep 42."
        let range = (raw as NSString).range(of: "Remove 17.")

        let mismatched = try transcriptionResponse(
            text: "Keep 42.",
            raw: raw,
            withdrawnRanges: [range],
            claimedTexts: ["Remove 18."]
        )
        XCTAssertThrowsError(try CleanupResponseDecoder.decode(mismatched, for: .init(input: .transcription(raw))))

        let outOfBounds = try transcriptionResponse(
            text: "Keep 42.",
            raw: raw,
            withdrawnRanges: [NSRange(location: range.location, length: raw.utf16.count + 1)],
            claimedTexts: ["Remove 17."]
        )
        XCTAssertThrowsError(try CleanupResponseDecoder.decode(outOfBounds, for: .init(input: .transcription(raw))))

        let overlapping = try transcriptionResponse(
            text: "Keep 42.",
            raw: raw,
            withdrawnRanges: [range, range]
        )
        XCTAssertThrowsError(try CleanupResponseDecoder.decode(overlapping, for: .init(input: .transcription(raw))))

        let noWithdrawalLanguage = "Remove 17. Then keep 42."
        let unverified = try transcriptionResponse(
            text: "Keep 42.",
            raw: noWithdrawalLanguage,
            withdrawnRanges: [(noWithdrawalLanguage as NSString).range(of: "Remove 17.")]
        )
        XCTAssertThrowsError(
            try CleanupResponseDecoder.decode(unverified, for: .init(input: .transcription(noWithdrawalLanguage)))
        )
    }

    func testRepeatedProtectedTokenOutsideClaimedOccurrenceRemainsMandatory() throws {
        let withdrawn = "Use port 8080."
        let raw = "\(withdrawn) I take back that instruction. Use port 8080 for production."
        let range = (raw as NSString).range(of: withdrawn)

        let valid = try transcriptionResponse(
            text: "Use port 8080 for production.",
            raw: raw,
            withdrawnRanges: [range]
        )
        XCTAssertNoThrow(try CleanupResponseDecoder.decode(valid, for: .init(input: .transcription(raw))))

        let substituted = try transcriptionResponse(
            text: "Use port 9090 for production.",
            raw: raw,
            withdrawnRanges: [range]
        )
        XCTAssertThrowsError(try CleanupResponseDecoder.decode(substituted, for: .init(input: .transcription(raw))))
    }

    func testCueLookalikeContinuingIntoOrdinarySpeechDoesNotAuthorizeWithdrawal() throws {
        let raw = "Wipe the cache at https://example.com. Scratch that disk and reboot."
        let response = try transcriptionResponse(
            text: "Scratch that disk and reboot.",
            raw: raw,
            withdrawnRanges: [(raw as NSString).range(of: "Wipe the cache at https://example.com.")]
        )

        XCTAssertThrowsError(try CleanupResponseDecoder.decode(response, for: .init(input: .transcription(raw))))
    }

    func testWithdrawnCueIsExcludedFromLengthBaseline() throws {
        let raw = "Email old@example.com. Scratch that. Hi."
        let response = try transcriptionResponse(
            text: "Hi.",
            raw: raw,
            withdrawnRanges: [(raw as NSString).range(of: "Email old@example.com.")]
        )

        let output = try CleanupResponseDecoder.decode(response, for: .init(input: .transcription(raw)))

        XCTAssertEqual(output, .transcription("Hi."))
    }

    func testLegacyRetractionFlagCannotBypassProtectedTokenValidation() {
        let raw = "Email owner@example.com and keep version 42."
        let response = #"{"intent":"transcription","text":"Please keep version 42 for the release.","retractionApplied":true}"#

        XCTAssertThrowsError(try CleanupResponseDecoder.decode(response, for: .init(input: .transcription(raw))))
    }

    func testResponseDecoderKeepsStrictValidationWithoutVerifiedRetraction() {
        let raw = "I want to name my child XYZ, or maybe just YZ. I think my wife would love YZ, but I am going with XYZ."
        let response = #"{"intent":"transcription","text":"I'll name my child YZ.","withdrawnSpans":[]}"#

        XCTAssertThrowsError(try CleanupResponseDecoder.decode(response, for: .init(input: .transcription(raw))))
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

    func testPromptResolvesExplicitRetractionsWithoutCollapsingOrdinaryIdeation() {
        let prompt = CleanupPrompt.system(request: .init(input: .transcription("hello")))

        XCTAssertTrue(prompt.contains("semantically determine"))
        XCTAssertTrue(prompt.contains("final intended wording"))
        XCTAssertTrue(prompt.contains("Brainstorming alternatives alone is not a retraction"))
        XCTAssertTrue(prompt.contains("withdrawnSpans"))
        XCTAssertTrue(prompt.contains("end-exclusive UTF-16"))
        XCTAssertFalse(prompt.contains("retractionApplied"))
    }

    func testPromptRendersSpokenSymbolNamesInsideDictatedIdentifiers() {
        let prompt = CleanupPrompt.system(request: .init(input: .transcription("hello")))
        XCTAssertTrue(prompt.contains(#""dot" as ".""#))
        XCTAssertTrue(prompt.contains(#""underscore" as "_""#))
        XCTAssertTrue(prompt.contains("never convert these words in ordinary prose"))
    }

    func testValidatorAcceptsSymbolRenderingBelowRawLengthBound() {
        XCTAssertNoThrow(try CleanupSafetyValidator.validate(
            raw: "foo underscore bar",
            cleaned: "foo_bar",
            vocabulary: []
        ))
    }

    func testValidatorAcceptsEmojiRenderingBelowRawLengthBound() {
        XCTAssertNoThrow(try CleanupSafetyValidator.validate(
            raw: "emoji heart",
            cleaned: "❤️",
            vocabulary: []
        ))
    }

    func testValidatorAcceptsMultiwordEmojiNameInBothWordOrders() {
        XCTAssertNoThrow(try CleanupSafetyValidator.validate(
            raw: "emoji red heart",
            cleaned: "❤️",
            vocabulary: []
        ))
        XCTAssertNoThrow(try CleanupSafetyValidator.validate(
            raw: "face with tears of joy emoji",
            cleaned: "😂",
            vocabulary: []
        ))
    }

    func testResponseDecoderAcceptsMultiwordEmojiRendering() throws {
        let response = #"{"intent":"transcription","text":"Nice work ❤️","withdrawnSpans":[]}"#
        let output = try CleanupResponseDecoder.decode(
            response,
            for: .init(input: .transcription("nice work emoji red heart"))
        )
        XCTAssertEqual(output, .transcription("Nice work ❤️"))
    }

    func testValidatorKeepsShrinkGuardWhenOutputContainsNoEmoji() {
        XCTAssertThrowsError(try CleanupSafetyValidator.validate(
            raw: "emoji accessibility and emoji rendering and emoji keyboards",
            cleaned: "Emoji topics.",
            vocabulary: []
        ))
    }

    func testValidatorKeepsShrinkGuardWhenOutputContainsNoMatchingSymbol() {
        XCTAssertThrowsError(try CleanupSafetyValidator.validate(
            raw: "underscore underscore underscore underscore underscore",
            cleaned: "Many underscores",
            vocabulary: []
        ))
    }

    func testValidatorStillRejectsShrinkWithoutSpokenTokens() {
        XCTAssertThrowsError(try CleanupSafetyValidator.validate(
            raw: "please write down every single thing I told you about yesterday",
            cleaned: "ok",
            vocabulary: []
        ))
    }

    func testResponseDecoderAcceptsSymbolAndEmojiRenderings() throws {
        let symbol = #"{"intent":"transcription","text":"so c.customer_email was generated","withdrawnSpans":[]}"#
        let symbolOutput = try CleanupResponseDecoder.decode(
            symbol,
            for: .init(input: .transcription("so C dot customer underscore email was generated"))
        )
        XCTAssertEqual(symbolOutput, .transcription("so c.customer_email was generated"))

        let emoji = #"{"intent":"transcription","text":"Great job ❤️","withdrawnSpans":[]}"#
        let emojiOutput = try CleanupResponseDecoder.decode(
            emoji,
            for: .init(input: .transcription("great job heart emoji"))
        )
        XCTAssertEqual(emojiOutput, .transcription("Great job ❤️"))
    }

    func testPromptRendersSpokenEmojiNamesAsEmoji() {
        let prompt = CleanupPrompt.system(request: .init(input: .transcription("hello")))
        XCTAssertTrue(prompt.contains(#""emoji heart" or "heart emoji""#))
        XCTAssertTrue(prompt.contains("matching emoji character"))
        XCTAssertTrue(prompt.contains("talking about emojis rather than dictating one"))
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

    private func transcriptionResponse(
        text: String,
        raw: String,
        withdrawnRanges: [NSRange],
        claimedTexts: [String]? = nil
    ) throws -> String {
        let source = raw as NSString
        let spans = try withdrawnRanges.enumerated().map { index, range -> [String: Any] in
            let claimedText: String
            if let claimedTexts {
                claimedText = claimedTexts[index]
            } else {
                guard range.location != NSNotFound,
                      range.location >= 0,
                      range.length >= 0,
                      NSMaxRange(range) <= source.length
                else {
                    throw ProviderError.invalidResponse
                }
                claimedText = source.substring(with: range)
            }
            return [
                "startUTF16": range.location,
                "endUTF16": NSMaxRange(range),
                "text": claimedText
            ]
        }
        let payload: [String: Any] = [
            "intent": "transcription",
            "text": text,
            "withdrawnSpans": spans
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
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
