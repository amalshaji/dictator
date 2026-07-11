import XCTest
@testable import DictatorCore

final class CoreTests: XCTestCase {
    func testPersonalizationValidationNormalizesAndRejectsVocabularyCollisions() throws {
        let existing = VocabularyEntry(value: "Dictator", variants: ["dictater"])
        var candidate = VocabularyEntry(value: "  OpenDrop  ", variants: [" open drop ", "OPEN DROP", ""])
        candidate = try PersonalizationValidator.validateVocabulary(candidate, among: [existing])
        XCTAssertEqual(candidate.value, "OpenDrop")
        XCTAssertEqual(candidate.variants, ["open drop"])
        XCTAssertThrowsError(try PersonalizationValidator.validateVocabulary(.init(value: "Dictater"), among: [existing]))
    }

    func testPersonalizationValidationRejectsDuplicateStyleAndSnippet() {
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
                input: .contextual(spokenText: "make it lowercase", selectedText: "HELLO WORLD")
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

        guard case .cleaned(let cleanupResult) = result else {
            return XCTFail("Expected cleaned transcript")
        }
        XCTAssertEqual(cleanupResult.output, .transcription("First sentence. Second sentence."))
        XCTAssertEqual(cleanupResult.provider, .groq)
        XCTAssertEqual(cleanupResult.model, "formatting-model")
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

        guard case .cleaned(let cleanupResult) = result else {
            return XCTFail("Expected transformed selection")
        }
        XCTAssertEqual(cleanupResult.output, .transformation("hello world"))
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

        guard case .failed(let reason) = result else {
            return XCTFail("Selection cleanup failure must stop processing")
        }
        XCTAssertEqual(reason, "The provider returned an invalid response.")
    }

    func testCleanupFailureWithoutSelectionFallsBackToTranscript() async {
        let cleanup = TranscriptCleanupConfiguration(
            provider: FailingCleanupProvider(),
            model: "failing-model",
            credentials: ProviderCredentials(apiKey: "shared-key")
        )

        let result = await TranscriptProcessor().process(
            rawText: "ordinary dictation",
            vocabulary: [],
            snippets: [],
            cleanup: cleanup
        )

        guard case .fallback(let text, let reason) = result else {
            return XCTFail("Ordinary dictation should retain its raw fallback")
        }
        XCTAssertEqual(text, "ordinary dictation")
        XCTAssertEqual(reason, "The provider returned an invalid response.")
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

        guard case .failed(let reason) = result else {
            return XCTFail("Oversized selection must stop processing")
        }
        XCTAssertEqual(reason, "Cleanup output was rejected: selected text is too long")
    }

    func testCleanupResponseDecoderRejectsTransformationWithoutSelection() {
        let response = #"{"intent":"transformation","text":"hello"}"#
        let request = CleanupRequest(input: .transcription("make it lowercase"))

        XCTAssertThrowsError(try CleanupResponseDecoder.decode(response, for: request)) { error in
            XCTAssertEqual(error as? ProviderError, .cleanupRejected("transformation requires selected text"))
        }
    }

    func testCleanupResponseDecoderRejectsTransformationWithEmptySelection() {
        let response = #"{"intent":"transformation","text":"hello"}"#
        let request = CleanupRequest(input: .contextual(spokenText: "make it lowercase", selectedText: ""))

        XCTAssertThrowsError(try CleanupResponseDecoder.decode(response, for: request)) { error in
            XCTAssertEqual(error as? ProviderError, .cleanupRejected("transformation requires selected text"))
        }
    }

    func testPricingCatalogUsesAudioDuration() {
        XCTAssertEqual(PricingCatalog.estimatedSTTCost(provider: .groq, model: "whisper-large-v3-turbo", audioSeconds: 3_600), Decimal(string: "0.04"))
        XCTAssertEqual(PricingCatalog.estimatedSTTCost(provider: .xAI, model: "grok-transcribe", audioSeconds: 1_800), Decimal(string: "0.05"))
    }

    func testGroqSTTPricingUsesTenSecondMinimum() {
        XCTAssertEqual(
            PricingCatalog.estimatedSTTCost(provider: .groq, model: "whisper-large-v3-turbo", audioSeconds: 1),
            PricingCatalog.estimatedSTTCost(provider: .groq, model: "whisper-large-v3-turbo", audioSeconds: 10)
        )
    }

    func testModelsDevPricingDecodesExactProviderAndModel() throws {
        let data = #"{"groq":{"models":{"openai/gpt-oss-20b":{"cost":{"input":0.1,"output":0.5}}}}}"#.data(using: .utf8)!
        let rates = try PricingService.decodeRates(from: data)
        XCTAssertEqual(rates["groq/openai/gpt-oss-20b"], .init(inputPerMillion: 0.1, outputPerMillion: 0.5))
        XCTAssertNil(PricingCatalog.estimatedLLMCost(provider: .groq, model: "similar-model", usage: .init(inputTokens: 10), rates: rates))
        XCTAssertEqual(PricingCatalog.estimatedLLMCost(provider: .groq, model: "openai/gpt-oss-20b", usage: .init(inputTokens: 1_000_000, outputTokens: 1_000_000), rates: rates), Decimal(string: "0.6"))
        XCTAssertEqual(PricingCatalog.estimatedLLMCost(provider: .groq, model: "openai/gpt-oss-20b", usage: .init(providerReportedCostUSD: 2), rates: rates), 2)
    }

    func testPricingServiceUsesFreshDiskCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let cache = directory.appending(path: "pricing.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let expected = PricingSnapshot(fetchedAt: Date(), rates: ["groq/test": .init(inputPerMillion: 1, outputPerMillion: 2)])
        try JSONEncoder().encode(expected).write(to: cache)
        let actual = try await PricingService(cacheURL: cache).refreshIfNeeded()
        XCTAssertEqual(actual, expected)
    }

    func testLegacyTranscriptDecodesWithoutPipelineLatencyOrRevisions() throws {
        let record = TranscriptRecord(rawText: "raw", finalText: "final", sttProvider: .groq, sttModel: "m", audioDuration: 1, sttLatency: 0.2, insertionOutcome: "typed")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        object.removeValue(forKey: "pipelineLatency"); object.removeValue(forKey: "revisions"); object.removeValue(forKey: "preferredRevisionID")
        let decoded = try JSONDecoder().decode(TranscriptRecord.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.pipelineLatency); XCTAssertTrue(decoded.revisions.isEmpty); XCTAssertEqual(decoded.currentText, "final")
    }

    func testUsageAnalyticsKeepsSTTAndLLMSeparate() {
        let record = TranscriptRecord(
            rawText: "hello", finalText: "Hello", sttProvider: .groq, sttModel: "whisper-large-v3-turbo",
            llmProvider: .groq, llmModel: "openai/gpt-oss-20b", audioDuration: 60, sttLatency: 0.3,
            llmUsage: .init(inputTokens: 100, outputTokens: 20), insertionOutcome: "typed"
        )
        let summary = UsageAnalytics.summarize([record], since: .distantPast, rates: PricingCatalog.fallbackRates)
        XCTAssertEqual(summary.dictations, 1); XCTAssertEqual(summary.cleanupRequests, 1)
        XCTAssertEqual(summary.inputTokens, 100); XCTAssertGreaterThan(summary.sttCost, 0); XCTAssertGreaterThan(summary.llmCost, 0)
    }

    func testPreferredRevisionSuppliesCurrentTextWithoutChangingOriginal() {
        let revision = TranscriptRevision(text: "Repaired", origin: .manual, repairLatency: 0.1)
        let record = TranscriptRecord(
            rawText: "Raw", finalText: "Original", sttProvider: .groq, sttModel: "m",
            audioDuration: 1, sttLatency: 0.2, pipelineLatency: 0.4, insertionOutcome: "typed",
            revisions: [revision], preferredRevisionID: revision.id
        )
        XCTAssertEqual(record.currentText, "Repaired")
        XCTAssertEqual(record.rawText, "Raw"); XCTAssertEqual(record.finalText, "Original"); XCTAssertEqual(record.pipelineLatency, 0.4)
    }

    func testRepairCleanupUsageCountsOnlyAsLLMUsage() {
        let revision = TranscriptRevision(
            text: "Repaired", origin: .cleanup, llmProvider: .groq, llmModel: "openai/gpt-oss-20b",
            repairLatency: 0.3, llmUsage: .init(inputTokens: 10, outputTokens: 3)
        )
        let record = TranscriptRecord(
            rawText: "raw", finalText: "original", sttProvider: .groq, sttModel: "whisper-large-v3-turbo",
            audioDuration: 60, sttLatency: 0.2, insertionOutcome: "typed", revisions: [revision]
        )
        let summary = UsageAnalytics.summarize([record], since: .distantPast, rates: PricingCatalog.fallbackRates)
        XCTAssertEqual(summary.dictations, 1); XCTAssertEqual(summary.audioSeconds, 60)
        XCTAssertEqual(summary.cleanupRequests, 1); XCTAssertEqual(summary.inputTokens, 10); XCTAssertEqual(summary.outputTokens, 3)
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
            output: .transcription("First sentence. Second sentence."),
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
        guard case .contextual(_, let selectedText) = request.input else {
            throw ProviderError.invalidResponse
        }
        return CleanupResult(
            output: .transformation(selectedText.lowercased()),
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
