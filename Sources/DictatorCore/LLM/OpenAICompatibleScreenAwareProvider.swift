import Foundation

public struct OpenAICompatibleScreenAwareProvider: ScreenAwareLLMProvider {
    public let metadata: ProviderMetadata
    private let client: OpenAICompatibleClient

    public init(
        kind: ProviderKind,
        displayName: String,
        defaultModel: String,
        defaultBaseURL: URL,
        transport: any HTTPTransport = URLSessionTransport()
    ) {
        metadata = ProviderMetadata(
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

    public func generate(
        request screenAware: ScreenAwareRequest,
        model: String,
        credentials: ProviderCredentials
    ) async throws -> ScreenAwareResult {
        let imageURL = "data:\(screenAware.imageMIMEType);base64,\(screenAware.imageData.base64EncodedString())"
        let result = try await client.complete(
            model: model,
            messages: [
                .init(role: "system", content: .text(ScreenAwarePrompt.system)),
                .init(role: "user", content: .parts([
                    .init(type: "text", text: try ScreenAwarePrompt.user(request: screenAware)),
                    .init(type: "image_url", imageURL: .init(url: imageURL))
                ]))
            ],
            credentials: credentials
        )
        let (intent, text) = try ScreenAwareResponseDecoder.decode(result.content, selectedText: screenAware.selectedText)
        return ScreenAwareResult(
            intent: intent,
            text: text,
            provider: metadata.kind,
            model: model,
            inputTokens: result.inputTokens,
            outputTokens: result.outputTokens,
            providerReportedCostUSD: result.providerReportedCostUSD,
            latency: result.latency
        )
    }
}

public extension OpenAICompatibleScreenAwareProvider {
    static func groq(transport: any HTTPTransport = URLSessionTransport()) -> Self {
        .init(kind: .groq, displayName: "Groq", defaultModel: "meta-llama/llama-4-scout-17b-16e-instruct", defaultBaseURL: URL(string: "https://api.groq.com/openai/v1")!, transport: transport)
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
