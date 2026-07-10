import Foundation

public enum CleanupProviderRegistry {
    public static func provider(for kind: ProviderKind) -> (any CleanupLLMProvider)? {
        switch kind {
        case .groq: OpenAICompatibleCleanupProvider.groq()
        case .cloudflare: CloudflareCleanupProvider()
        case .gemini: GeminiCleanupProvider()
        case .xAI: OpenAICompatibleCleanupProvider.xAI()
        case .openRouter: OpenAICompatibleCleanupProvider.openRouter()
        case .openAICompatible: OpenAICompatibleCleanupProvider.custom()
        default: nil
        }
    }

    public static var metadata: [LLMProviderMetadata] {
        [OpenAICompatibleCleanupProvider.groq().metadata, CloudflareCleanupProvider().metadata,
         GeminiCleanupProvider().metadata, OpenAICompatibleCleanupProvider.xAI().metadata,
         OpenAICompatibleCleanupProvider.openRouter().metadata, OpenAICompatibleCleanupProvider.custom().metadata]
    }
}

