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

    func testPromptFormatsSpokenComparisonsAndOrderedLists() {
        let prompt = CleanupPrompt.system(request: .init(input: .transcription("hello")))

        XCTAssertTrue(prompt.contains(#""greater than or equal to" as ">=""#))
        XCTAssertTrue(prompt.contains(#""greater there or equal to""#))
        XCTAssertTrue(prompt.contains("ordered or numbered list"))
        XCTAssertTrue(prompt.contains("dictates a numbered enumeration of items"))
        XCTAssertTrue(prompt.contains("consecutive numbers starting at 1"))
        XCTAssertTrue(prompt.contains("Never turn numbers used in ordinary prose into a list"))
        XCTAssertTrue(prompt.contains("one item per line"))
        XCTAssertTrue(prompt.contains("Preserve every item and its order"))
    }

    func testPromptResolvesInlineCorrectionsToFinalIntendedWording() {
        let prompt = CleanupPrompt.system(request: .init(input: .transcription("hello")))

        XCTAssertTrue(prompt.contains("correctionSpans"))
        XCTAssertTrue(prompt.contains("I want to order some flowers. No, no, no, lilies"))
        XCTAssertTrue(prompt.contains("I want to order some lilies."))
        XCTAssertTrue(prompt.contains("smallest abandoned word or phrase"))
        XCTAssertTrue(prompt.contains("Do not enumerate correction cue phrases"))
    }

    func testPromptRendersSpokenSymbolNamesInsideDictatedIdentifiers() {
        let prompt = CleanupPrompt.system(request: .init(input: .transcription("hello")))
        XCTAssertTrue(prompt.contains(#""dot" as ".""#))
        XCTAssertTrue(prompt.contains(#""underscore" as "_""#))
        XCTAssertTrue(prompt.contains("never convert these words in ordinary prose"))
    }

    func testValidatorAcceptsSymbolRenderingWithVerifiedSpan() {
        XCTAssertNoThrow(try CleanupSafetyValidator.validate(
            raw: "foo underscore bar",
            cleaned: "foo_bar",
            vocabulary: [],
            renderedSpans: [.init(startUTF16: 4, endUTF16: 14, text: "underscore", rendered: "_")]
        ))
    }

    func testResponseDecoderAcceptsSpokenComparisonRendering() throws {
        let raw = "Exceeding the maximum number of tokens allowed: 5674 greater there or equal to 1024."
        let source = "greater there or equal to"
        let range = (raw as NSString).range(of: source)
        let response = try responseJSON([
            "intent": "transcription",
            "text": "Exceeding the maximum number of tokens allowed: 5674 >= 1024.",
            "withdrawnSpans": [],
            "renderedSpans": [[
                "startUTF16": range.location,
                "endUTF16": NSMaxRange(range),
                "text": source,
                "rendered": ">="
            ]]
        ])

        let output = try CleanupResponseDecoder.decode(response, for: .init(input: .transcription(raw)))

        XCTAssertEqual(output, .transcription("Exceeding the maximum number of tokens allowed: 5674 >= 1024."))
    }

    func testResponseDecoderAcceptsScopedInlineCorrection() throws {
        let raw = "Use 5674 tokens. No, no, no, use 1024 tokens."
        let response = try correctionResponse(
            text: "Use 1024 tokens.",
            raw: raw,
            abandoned: "Use 5674 tokens",
            replacement: "use 1024 tokens"
        )

        let output = try CleanupResponseDecoder.decode(response, for: .init(input: .transcription(raw)))

        XCTAssertEqual(output, .transcription("Use 1024 tokens."))
    }

    func testResponseDecoderAcceptsExplicitCorrectionCommand() throws {
        let raw = "Use 5674 tokens. Correction, use 1024 tokens."
        let response = try correctionResponse(
            text: "Use 1024 tokens.",
            raw: raw,
            abandoned: "Use 5674 tokens",
            replacement: "use 1024 tokens"
        )

        let output = try CleanupResponseDecoder.decode(response, for: .init(input: .transcription(raw)))

        XCTAssertEqual(output, .transcription("Use 1024 tokens."))
    }

    func testResponseDecoderKeepsSentenceContextForFlowersCorrection() throws {
        let raw = "I want to order some flowers. No, no, no, lilies."
        let response = try correctionResponse(
            text: "I want to order some lilies.",
            raw: raw,
            abandoned: "flowers",
            replacement: "lilies"
        )

        let output = try CleanupResponseDecoder.decode(response, for: .init(input: .transcription(raw)))

        XCTAssertEqual(output, .transcription("I want to order some lilies."))
    }

    func testResponseDecoderAcceptsExplicitOrderedListFormatting() throws {
        let raw = "Make an ordered list: first, connect the microphone; second, start dictating; third, review the transcript."
        let text = """
        1. Connect the microphone.
        2. Start dictating.
        3. Review the transcript.
        """
        let response = try responseJSON([
            "intent": "transcription",
            "text": text,
            "withdrawnSpans": [],
            "correctionSpans": [],
            "renderedSpans": []
        ])

        let output = try CleanupResponseDecoder.decode(response, for: .init(input: .transcription(raw)))

        XCTAssertEqual(output, .transcription(text))
    }

    func testResponseDecoderAcceptsDictatedNumberedEnumerationFormatting() throws {
        let raw = "These are the options available: 1 mini statement, 2 detailed statement, 3 closed deposit, 4 deposit certificate, 5 nominee, 6 form 121."
        let text = """
        These are the options available:
        1. Mini statement
        2. Detailed statement
        3. Closed deposit
        4. Deposit certificate
        5. Nominee
        6. Form 121
        """
        let response = try responseJSON([
            "intent": "transcription",
            "text": text,
            "withdrawnSpans": [],
            "correctionSpans": [],
            "renderedSpans": []
        ])

        let output = try CleanupResponseDecoder.decode(response, for: .init(input: .transcription(raw)))

        XCTAssertEqual(output, .transcription(text))
    }

    func testCorrectionSpanCannotRemoveProtectedValuesOutsideItsRange() throws {
        let raw = "Keep owner@example.com and https://keep.example. Use 5674 tokens. No, no, use 1024 tokens."
        let unsafeOutputs = [
            "Keep someone@example.com and https://keep.example. Use 1024 tokens.",
            "Keep owner@example.com and https://other.example. Use 1024 tokens.",
            "Keep owner@example.com and https://keep.example. Use 2048 tokens."
        ]

        for text in unsafeOutputs {
            let response = try correctionResponse(
                text: text,
                raw: raw,
                abandoned: "Use 5674 tokens",
                replacement: "use 1024 tokens"
            )

            XCTAssertThrowsError(try CleanupResponseDecoder.decode(response, for: .init(input: .transcription(raw))))
        }
    }

    func testCorrectionSpanRejectsOrdinarySequenceAsCorrectionCue() throws {
        let raw = "Use 5674 tokens and use 1024 tokens."
        let response = try correctionResponse(
            text: "Use 1024 tokens.",
            raw: raw,
            abandoned: "Use 5674 tokens",
            replacement: "use 1024 tokens"
        )

        XCTAssertThrowsError(try CleanupResponseDecoder.decode(response, for: .init(input: .transcription(raw))))
    }

    func testValidatorRejectsUnverifiedComparisonRendering() {
        XCTAssertThrowsError(try CleanupSafetyValidator.validate(
            raw: "We have greater expectations.",
            cleaned: "We have > expectations.",
            vocabulary: [],
            renderedSpans: [.init(startUTF16: 8, endUTF16: 15, text: "greater", rendered: ">")]
        ))
    }

    func testValidatorAcceptsEmojiRenderingWithVerifiedSpan() {
        XCTAssertNoThrow(try CleanupSafetyValidator.validate(
            raw: "emoji heart",
            cleaned: "❤️",
            vocabulary: [],
            renderedSpans: [.init(startUTF16: 0, endUTF16: 11, text: "emoji heart", rendered: "❤️")]
        ))
    }

    func testValidatorAcceptsMultiwordEmojiNameInBothWordOrders() {
        XCTAssertNoThrow(try CleanupSafetyValidator.validate(
            raw: "emoji red heart",
            cleaned: "❤️",
            vocabulary: [],
            renderedSpans: [.init(startUTF16: 0, endUTF16: 15, text: "emoji red heart", rendered: "❤️")]
        ))
        XCTAssertNoThrow(try CleanupSafetyValidator.validate(
            raw: "face with tears of joy emoji",
            cleaned: "😂",
            vocabulary: [],
            renderedSpans: [.init(startUTF16: 0, endUTF16: 28, text: "face with tears of joy emoji", rendered: "😂")]
        ))
    }

    func testValidatorKeepsShrinkGuardWhenNoRenderedSpansClaimed() {
        XCTAssertThrowsError(try CleanupSafetyValidator.validate(
            raw: "emoji accessibility and emoji rendering and emoji keyboards",
            cleaned: "Emoji topics.",
            vocabulary: []
        ))
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

    func testValidatorRejectsUnverifiedRenderedSpans() {
        let raw = "emoji heart underscore red heart"

        // source text does not match the claimed offsets
        XCTAssertThrowsError(try CleanupSafetyValidator.validate(
            raw: raw, cleaned: "❤️ _ red heart", vocabulary: [],
            renderedSpans: [.init(startUTF16: 0, endUTF16: 11, text: "emoji hearts", rendered: "❤️")]
        ))
        // rendered character absent from the cleaned output
        XCTAssertThrowsError(try CleanupSafetyValidator.validate(
            raw: raw, cleaned: "no heart present underscore red heart", vocabulary: [],
            renderedSpans: [.init(startUTF16: 0, endUTF16: 11, text: "emoji heart", rendered: "❤️")]
        ))
        // span text is neither a symbol word nor an emoji name phrase
        XCTAssertThrowsError(try CleanupSafetyValidator.validate(
            raw: raw, cleaned: "emoji heart underscore ❤️", vocabulary: [],
            renderedSpans: [.init(startUTF16: 23, endUTF16: 32, text: "red heart", rendered: "❤️")]
        ))
        // symbol word paired with the wrong character
        XCTAssertThrowsError(try CleanupSafetyValidator.validate(
            raw: raw, cleaned: "emoji heart - red heart", vocabulary: [],
            renderedSpans: [.init(startUTF16: 12, endUTF16: 22, text: "underscore", rendered: "-")]
        ))
        // rendered must be a single character
        XCTAssertThrowsError(try CleanupSafetyValidator.validate(
            raw: raw, cleaned: "<3 underscore red heart", vocabulary: [],
            renderedSpans: [.init(startUTF16: 0, endUTF16: 11, text: "emoji heart", rendered: "<3")]
        ))
    }

    func testResponseDecoderAcceptsSymbolAndEmojiRenderings() throws {
        let symbol = #"{"intent":"transcription","text":"so c.customer_email was generated","withdrawnSpans":[],"renderedSpans":[{"startUTF16":5,"endUTF16":8,"text":"dot","rendered":"."},{"startUTF16":18,"endUTF16":28,"text":"underscore","rendered":"_"}]}"#
        let symbolOutput = try CleanupResponseDecoder.decode(
            symbol,
            for: .init(input: .transcription("so C dot customer underscore email was generated"))
        )
        XCTAssertEqual(symbolOutput, .transcription("so c.customer_email was generated"))

        let emoji = #"{"intent":"transcription","text":"Great job ❤️","withdrawnSpans":[],"renderedSpans":[{"startUTF16":10,"endUTF16":21,"text":"heart emoji","rendered":"❤️"}]}"#
        let emojiOutput = try CleanupResponseDecoder.decode(
            emoji,
            for: .init(input: .transcription("great job heart emoji"))
        )
        XCTAssertEqual(emojiOutput, .transcription("Great job ❤️"))
    }

    func testResponseDecoderAcceptsMultiwordEmojiRendering() throws {
        let response = #"{"intent":"transcription","text":"Nice work ❤️","withdrawnSpans":[],"renderedSpans":[{"startUTF16":10,"endUTF16":25,"text":"emoji red heart","rendered":"❤️"}]}"#
        let output = try CleanupResponseDecoder.decode(
            response,
            for: .init(input: .transcription("nice work emoji red heart"))
        )
        XCTAssertEqual(output, .transcription("Nice work ❤️"))
    }

    func testPromptRendersSpokenEmojiNamesAsEmoji() {
        let prompt = CleanupPrompt.system(request: .init(input: .transcription("hello")))
        XCTAssertTrue(prompt.contains(#""emoji heart" or "heart emoji""#))
        XCTAssertTrue(prompt.contains("matching emoji character"))
        XCTAssertTrue(prompt.contains("talking about emojis rather than dictating one"))
        XCTAssertTrue(prompt.contains("renderedSpans"))
        XCTAssertTrue(prompt.contains("the exact symbol, operator, or emoji that replaced it"))
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

    func testResponseDecoderRejectsCorrectionSpanForTransformation() throws {
        let response = try responseJSON([
            "intent": "transformation",
            "text": "hello",
            "correctionSpans": [[
                "startUTF16": 0,
                "endUTF16": 4,
                "text": "make",
                "replacementStartUTF16": 5,
                "replacementEndUTF16": 7,
                "replacementText": "it"
            ]]
        ])

        XCTAssertThrowsError(
            try CleanupResponseDecoder.decode(
                response,
                for: .init(input: .contextual(spokenText: "make it lowercase", selectedText: "HELLO"))
            )
        ) { error in
            XCTAssertEqual(error as? ProviderError, .cleanupRejected("transformation cannot report correction spans"))
        }
    }

    private func responseJSON(_ payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func correctionResponse(
        text: String,
        raw: String,
        abandoned: String,
        replacement: String
    ) throws -> String {
        let abandonedRange = (raw as NSString).range(of: abandoned)
        let replacementRange = (raw as NSString).range(of: replacement)
        return try responseJSON([
            "intent": "transcription",
            "text": text,
            "withdrawnSpans": [],
            "renderedSpans": [],
            "correctionSpans": [[
                "startUTF16": abandonedRange.location,
                "endUTF16": NSMaxRange(abandonedRange),
                "text": abandoned,
                "replacementStartUTF16": replacementRange.location,
                "replacementEndUTF16": NSMaxRange(replacementRange),
                "replacementText": replacement
            ]]
        ])
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
