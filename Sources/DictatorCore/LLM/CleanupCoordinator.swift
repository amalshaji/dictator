import Foundation

public struct CleanupCoordinator: Sendable {
    private static let maximumSelectedTextLength = 20_000

    public init() {}

    public func cleanOrFallback(
        request: CleanupRequest,
        provider: any CleanupLLMProvider,
        model: String,
        credentials: ProviderCredentials,
        timeout: Duration = .milliseconds(1_500)
    ) async -> CleanupOutcome {
        do {
            if case .contextual(_, let selectedText) = request.input,
               selectedText.count > Self.maximumSelectedTextLength {
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
            switch request.input {
            case .transcription(let text):
                return .transcriptionFallback(text, reason: error.localizedDescription)
            case .contextual:
                return .failed(error.localizedDescription)
            }
        }
    }
}

public enum CleanupOutcome: Equatable, Sendable {
    case cleaned(CleanupResult)
    case transcriptionFallback(String, reason: String)
    case failed(String)
}
