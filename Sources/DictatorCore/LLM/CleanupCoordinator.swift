import Foundation

public struct CleanupCoordinator: Sendable {
    public init() {}

    public func cleanOrFallback(
        rawText: String,
        provider: any CleanupLLMProvider,
        model: String,
        credentials: ProviderCredentials,
        vocabulary: [VocabularyEntry],
        styleInstruction: String? = nil,
        timeout: Duration = .milliseconds(1_500)
    ) async -> CleanupOutcome {
        let request = CleanupRequest(transcript: rawText, vocabulary: vocabulary, styleInstruction: styleInstruction)
        do {
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
            return .fallback(rawText, reason: error.localizedDescription)
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
