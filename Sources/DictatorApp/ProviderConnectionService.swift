import CryptoKit
import DictatorCore
import Foundation

@MainActor
final class ProviderConnectionService {
    private let defaults: UserDefaults
    private let screenAwareProviderResolver: (ProviderKind) -> (any ScreenAwareLLMProvider)?

    init(
        defaults: UserDefaults,
        screenAwareProvider: @escaping (ProviderKind) -> (any ScreenAwareLLMProvider)?
    ) {
        self.defaults = defaults
        screenAwareProviderResolver = screenAwareProvider
    }

    func screenAwareProvider(for kind: ProviderKind) -> (any ScreenAwareLLMProvider)? {
        screenAwareProviderResolver(kind)
    }

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
        case .screenAware:
            guard let implementation = screenAwareProvider(for: provider) else {
                throw ProviderError.invalidConfiguration("This screen-aware provider is unavailable.")
            }
            guard ScreenAwareModelCapabilities.capability(provider: provider, model: model) != .unsupported else {
                throw ProviderError.invalidConfiguration("This model is known not to support image input.")
            }
            _ = try await implementation.generate(
                request: ScreenAwareConnectionProbe.request(),
                model: model,
                credentials: credentials
            )
            confirmScreenAwareModel(provider: provider, model: model, credentials: credentials)
        }
    }

    func isScreenAwareModelConfirmed(
        provider: ProviderKind,
        model: String,
        credentials: ProviderCredentials
    ) -> Bool {
        defaults.string(forKey: confirmationKey(provider: provider, model: model))
            == fingerprint(provider: provider, model: model, credentials: credentials)
    }

    func confirmScreenAwareModel(
        provider: ProviderKind,
        model: String,
        credentials: ProviderCredentials
    ) {
        defaults.set(
            fingerprint(provider: provider, model: model, credentials: credentials),
            forKey: confirmationKey(provider: provider, model: model)
        )
    }

    private func confirmationKey(provider: ProviderKind, model: String) -> String {
        "screenAwareModelConfirmed.\(provider.rawValue).\(model)"
    }

    private func fingerprint(
        provider: ProviderKind,
        model: String,
        credentials: ProviderCredentials
    ) -> String {
        let components = [
            provider.rawValue,
            model.trimmingCharacters(in: .whitespacesAndNewlines),
            credentials.apiKey,
            credentials.accountID ?? "",
            credentials.baseURL?.absoluteString ?? "",
        ]
        let digest = SHA256.hash(data: Data(components.joined(separator: "\0").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
