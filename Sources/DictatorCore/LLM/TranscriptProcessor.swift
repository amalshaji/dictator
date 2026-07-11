import Foundation

public struct TranscriptCleanupConfiguration: Sendable {
    public let provider: any CleanupLLMProvider
    public let model: String
    public let credentials: ProviderCredentials
    public let styleInstruction: String?

    public init(
        provider: any CleanupLLMProvider,
        model: String,
        credentials: ProviderCredentials,
        styleInstruction: String? = nil
    ) {
        self.provider = provider
        self.model = model
        self.credentials = credentials
        self.styleInstruction = styleInstruction
    }
}

public struct ProcessedTranscript: Sendable {
    public let finalText: String
    public let cleanupOutcome: CleanupOutcome?

    public var cleanupResult: CleanupResult? {
        guard case .cleaned(let result) = cleanupOutcome else { return nil }
        return result
    }

    public var cleanupFallbackReason: String? {
        guard case .fallback(_, let reason) = cleanupOutcome else { return nil }
        return reason
    }
}

public struct TranscriptProcessor: Sendable {
    public init() {}

    public func process(
        rawText: String,
        vocabulary: [VocabularyEntry],
        snippets: [SnippetEntry],
        cleanup: TranscriptCleanupConfiguration?
    ) async -> ProcessedTranscript {
        let normalized = VocabularyNormalizer.normalize(rawText, vocabulary: vocabulary)
        let expanded = SnippetExpander.expand(normalized, snippets: snippets)
        guard let cleanup else {
            return ProcessedTranscript(finalText: expanded, cleanupOutcome: nil)
        }

        let outcome = await CleanupCoordinator().cleanOrFallback(
            rawText: expanded,
            provider: cleanup.provider,
            model: cleanup.model,
            credentials: cleanup.credentials,
            vocabulary: vocabulary,
            styleInstruction: cleanup.styleInstruction
        )
        return ProcessedTranscript(finalText: outcome.text, cleanupOutcome: outcome)
    }
}
