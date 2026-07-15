import Foundation

public enum ScreenAwareProviderRegistry {
    public static func provider(for kind: ProviderKind) -> (any ScreenAwareLLMProvider)? {
        switch kind {
        case .groq: OpenAICompatibleScreenAwareProvider.groq()
        case .gemini: GeminiScreenAwareProvider()
        case .xAI: OpenAICompatibleScreenAwareProvider.xAI()
        case .openRouter: OpenAICompatibleScreenAwareProvider.openRouter()
        case .openAICompatible: OpenAICompatibleScreenAwareProvider.custom()
        default: nil
        }
    }

    public static var metadata: [ProviderMetadata] {
        [OpenAICompatibleScreenAwareProvider.groq().metadata,
         GeminiScreenAwareProvider().metadata,
         OpenAICompatibleScreenAwareProvider.xAI().metadata,
         OpenAICompatibleScreenAwareProvider.openRouter().metadata,
         OpenAICompatibleScreenAwareProvider.custom().metadata]
    }
}

public enum ScreenAwareModelCapability: Equatable, Sendable {
    case supported
    case unsupported
    case requiresConfirmation
}

public enum ScreenAwareModelCapabilities {
    public static func capability(provider: ProviderKind, model: String) -> ScreenAwareModelCapability {
        let normalized = model.lowercased()
        if provider == .gemini, normalized.hasPrefix("gemini-") {
            return .supported
        }
        if provider == .groq, normalized == "meta-llama/llama-4-scout-17b-16e-instruct" {
            return .supported
        }
        if normalized == "openai/gpt-oss-20b" || normalized.hasPrefix("@cf/") {
            return .unsupported
        }
        return .requiresConfirmation
    }
}
