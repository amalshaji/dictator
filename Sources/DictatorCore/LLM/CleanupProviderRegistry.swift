import Foundation

public enum CleanupProviderRegistry {
    public static func provider(for kind: ProviderKind) -> (any CleanupLLMProvider)? {
        switch kind {
        case .groq: OpenAICompatibleCleanupProvider.groq()
        case .cerebras: OpenAICompatibleCleanupProvider.cerebras()
        case .gemini: OpenAICompatibleCleanupProvider.gemini()
        case .openRouter: OpenAICompatibleCleanupProvider.openRouter()
        case .openAICompatible: OpenAICompatibleCleanupProvider.custom()
        default: nil
        }
    }

    public static let metadata: [ProviderMetadata] = [
        OpenAICompatibleCleanupProvider.groq().metadata, OpenAICompatibleCleanupProvider.cerebras().metadata,
        OpenAICompatibleCleanupProvider.gemini().metadata,
        OpenAICompatibleCleanupProvider.openRouter().metadata,
        OpenAICompatibleCleanupProvider.custom().metadata
    ]
}
