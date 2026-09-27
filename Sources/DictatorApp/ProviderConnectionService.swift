import DictatorCore
import Foundation

@MainActor
final class ProviderConnectionService {
    func test(
        purpose: ProviderPurpose,
        provider: ProviderKind,
        model: String,
        credentials: ProviderCredentials
    ) async throws {
        switch purpose {
        case .speechToText:
            guard let implementation = ProviderRegistry.sttProvider(for: provider) else {
                throw ProviderError.invalidConfiguration("This speech provider is unavailable.")
            }
            try await implementation.validate(credentials: credentials)
        case .cleanup:
            guard let implementation = CleanupProviderRegistry.provider(for: provider) else {
                throw ProviderError.invalidConfiguration("This cleanup provider is unavailable.")
            }
            try await implementation.validate(credentials: credentials)
        }
    }
}
