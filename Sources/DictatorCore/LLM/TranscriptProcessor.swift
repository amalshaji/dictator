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

public enum ProcessedTranscript: Equatable, Sendable {
    case raw(String)
    case cleaned(CleanupResult)
    case fallback(String, reason: String)
    case offlineFallback(String, reason: String)
    case failed(String)
}

public struct TranscriptProcessor: Sendable {
    public init() {}

    public func process(
        rawText: String,
        selectedText: String? = nil,
        vocabulary: [VocabularyEntry],
        snippets: [SnippetEntry],
        cleanup: TranscriptCleanupConfiguration?
    ) async -> ProcessedTranscript {
        let normalized = VocabularyNormalizer.normalize(rawText, vocabulary: vocabulary)
        let expanded = SnippetExpander.expand(normalized, snippets: snippets)
        guard let cleanup else {
            return .raw(expanded)
        }

        let input: CleanupInput = selectedText.flatMap { $0.isEmpty ? nil : $0 }.map {
            .contextual(spokenText: expanded, selectedText: $0)
        } ?? .transcription(expanded)
        let request = CleanupRequest(
            input: input,
            vocabulary: vocabulary,
            styleInstruction: cleanup.styleInstruction
        )
        let outcome = await CleanupCoordinator().cleanOrFallback(
            request: request,
            provider: cleanup.provider,
            model: cleanup.model,
            credentials: cleanup.credentials,
        )
        switch outcome {
        case .cleaned(let result): return .cleaned(result)
        case .transcriptionFallback(let text, let reason): return .fallback(text, reason: reason)
        case .offlineFallback(let text, let reason): return .offlineFallback(text, reason: reason)
        case .failed(let reason): return .failed(reason)
        }
    }
}
