import Foundation

public struct GeminiScreenAwareProvider: ScreenAwareLLMProvider {
    public let metadata = ProviderMetadata(
        kind: .gemini,
        displayName: "Google Gemini",
        defaultModel: "gemini-2.5-flash-lite",
        models: ["gemini-2.5-flash-lite"],
        requiresAccountID: false
    )

    private let client: GeminiClient
    public init(transport: any HTTPTransport = URLSessionTransport()) { client = GeminiClient(transport: transport) }

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
        let result = try await client.generate(
            model: model,
            systemPrompt: ScreenAwarePrompt.system,
            userParts: [
                .init(text: try ScreenAwarePrompt.user(request: screenAware)),
                .init(inlineData: .init(
                    mimeType: screenAware.imageMIMEType,
                    data: screenAware.imageData.base64EncodedString()
                ))
            ],
            credentials: credentials
        )
        let (intent, text) = try ScreenAwareResponseDecoder.decode(result.content, selectedText: screenAware.selectedText)
        return ScreenAwareResult(
            intent: intent,
            text: text,
            provider: .gemini,
            model: model,
            inputTokens: result.inputTokens,
            outputTokens: result.outputTokens,
            latency: result.latency
        )
    }
}
