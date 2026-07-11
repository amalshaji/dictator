import Foundation

public struct CleanupCoordinator: Sendable {
    private static let maximumSelectedTextLength = 20_000

    public init() {}

    public func cleanOrFallback(
        rawText: String,
        provider: any CleanupLLMProvider,
        model: String,
        credentials: ProviderCredentials,
        vocabulary: [VocabularyEntry],
        selectedText: String? = nil,
        styleInstruction: String? = nil,
        timeout: Duration = .milliseconds(1_500)
    ) async -> CleanupOutcome {
        let request = CleanupRequest(
            transcript: rawText,
            selectedText: selectedText,
            vocabulary: vocabulary,
            styleInstruction: styleInstruction
        )
        do {
            guard request.selectedText?.count ?? 0 <= Self.maximumSelectedTextLength else {
                throw ProviderError.cleanupRejected("selected text is too long")
            }
            let result = try await withThrowingTaskGroup(of: CleanupResult.self) { group in
                group.addTask { try await provider.clean(request: request, model: model, credentials: credentials) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw CancellationError()
                }
                defer { group.cancelAll() }
                guard let value = try await group.next() else { throw ProviderError.invalidResponse }
                return value
            }
            return .cleaned(result)
        } catch {
            return .fallback(selectedText ?? rawText, reason: error.localizedDescription)
        }
    }
}

public enum CleanupOutcome: Equatable, Sendable {
    case cleaned(CleanupResult)
    case fallback(String, reason: String)

    public var text: String {
        switch self {
        case .cleaned(let result): result.text
        case .fallback(let text, _): text
        }
    }
}
