import Foundation

public struct GeminiCleanupProvider: CleanupLLMProvider {
    public let metadata = ProviderMetadata(
        kind: .gemini,
        displayName: "Google Gemini",
        defaultModel: "gemini-2.5-flash-lite",
        models: ["gemini-2.5-flash-lite"],
        requiresAccountID: false
    )

    private let client: GeminiClient
    public init(transport: any HTTPTransport = URLSessionTransport()) { client = GeminiClient(transport: transport) }

    public func validate(credentials: ProviderCredentials) async throws { try await client.validate(credentials: credentials) }

    public func listModels(credentials: ProviderCredentials) async throws -> [String] {
        try await client.listModels(credentials: credentials)
    }

    public func clean(request cleanup: CleanupRequest, model: String, credentials: ProviderCredentials) async throws -> CleanupResult {
        let result = try await client.generate(
            model: model,
            systemPrompt: CleanupPrompt.system(
                vocabulary: cleanup.vocabulary,
                styleInstruction: cleanup.styleInstruction
            ),
            userParts: [.init(text: try CleanupPrompt.user(request: cleanup))],
            credentials: credentials
        )
        let output = try CleanupResponseDecoder.decode(result.content, for: cleanup)
        return CleanupResult(
            output: output,
            provider: .gemini,
            model: model,
            inputTokens: result.inputTokens,
            outputTokens: result.outputTokens,
            latency: result.latency
        )
    }
}
