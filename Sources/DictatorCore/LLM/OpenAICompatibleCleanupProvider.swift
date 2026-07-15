import Foundation

public struct OpenAICompatibleCleanupProvider: CleanupLLMProvider {
    public let metadata: ProviderMetadata
    private let client: OpenAICompatibleClient

    public init(
        kind: ProviderKind,
        displayName: String,
        defaultModel: String,
        defaultBaseURL: URL,
        transport: any HTTPTransport = URLSessionTransport()
    ) {
        self.metadata = ProviderMetadata(
            kind: kind,
            displayName: displayName,
            defaultModel: defaultModel,
            models: [defaultModel],
            requiresAccountID: false
        )
        client = OpenAICompatibleClient(kind: kind, defaultBaseURL: defaultBaseURL, transport: transport)
    }

    public func validate(credentials: ProviderCredentials) async throws {
        try await client.validate(credentials: credentials)
    }

    public func listModels(credentials: ProviderCredentials) async throws -> [String] {
        try await client.listModels(credentials: credentials)
    }

    public func clean(request cleanup: CleanupRequest, model: String, credentials: ProviderCredentials) async throws -> CleanupResult {
        let result = try await client.complete(
            model: model,
            messages: [
                .init(role: "system", content: .text(CleanupPrompt.system(
                    vocabulary: cleanup.vocabulary,
                    styleInstruction: cleanup.styleInstruction
                ))),
                .init(role: "user", content: .text(try CleanupPrompt.user(request: cleanup)))
            ],
            credentials: credentials
        )
        let output = try CleanupResponseDecoder.decode(result.content, for: cleanup)
        return CleanupResult(
            output: output,
            provider: metadata.kind,
            model: model,
            inputTokens: result.inputTokens,
            outputTokens: result.outputTokens,
            providerReportedCostUSD: result.providerReportedCostUSD,
            latency: result.latency
        )
    }
}

public extension OpenAICompatibleCleanupProvider {
    static func groq(transport: any HTTPTransport = URLSessionTransport()) -> Self {
        .init(kind: .groq, displayName: "Groq", defaultModel: "openai/gpt-oss-20b", defaultBaseURL: URL(string: "https://api.groq.com/openai/v1")!, transport: transport)
    }

    static func xAI(transport: any HTTPTransport = URLSessionTransport()) -> Self {
        .init(kind: .xAI, displayName: "xAI", defaultModel: "grok-4.20-0309-non-reasoning", defaultBaseURL: URL(string: "https://api.x.ai/v1")!, transport: transport)
    }

    static func openRouter(transport: any HTTPTransport = URLSessionTransport()) -> Self {
        .init(kind: .openRouter, displayName: "OpenRouter", defaultModel: "openrouter/free", defaultBaseURL: URL(string: "https://openrouter.ai/api/v1")!, transport: transport)
    }

    static func custom(transport: any HTTPTransport = URLSessionTransport()) -> Self {
        .init(kind: .openAICompatible, displayName: "OpenAI-compatible", defaultModel: "", defaultBaseURL: URL(string: "https://example.invalid/v1")!, transport: transport)
    }
}
