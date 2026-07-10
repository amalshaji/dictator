import Foundation

public struct OpenAICompatibleCleanupProvider: CleanupLLMProvider {
    public let metadata: LLMProviderMetadata
    private let defaultBaseURL: URL
    private let transport: any HTTPTransport

    public init(
        kind: ProviderKind,
        displayName: String,
        defaultModel: String,
        defaultBaseURL: URL,
        transport: any HTTPTransport = URLSessionTransport()
    ) {
        self.metadata = LLMProviderMetadata(
            kind: kind,
            displayName: displayName,
            defaultModel: defaultModel,
            requiresAccountID: false,
            supportsDynamicModels: true
        )
        self.defaultBaseURL = defaultBaseURL
        self.transport = transport
    }

    public func validate(credentials: ProviderCredentials) async throws {
        _ = try await listModels(credentials: credentials)
    }

    public func listModels(credentials: ProviderCredentials) async throws -> [String] {
        guard !credentials.apiKey.isEmpty else { throw ProviderError.missingCredential("API key") }
        let baseURL = credentials.baseURL ?? defaultBaseURL
        var request = URLRequest(url: baseURL.appending(path: "models"))
        request.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.data(for: request)
        try HTTPHelpers.requireSuccess(data: data, response: response)
        let payload = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return payload.data.map(\.id).sorted()
    }

    public func clean(request cleanup: CleanupRequest, model: String, credentials: ProviderCredentials) async throws -> CleanupResult {
        guard !credentials.apiKey.isEmpty else { throw ProviderError.missingCredential("API key") }
        let started = ContinuousClock.now
        let baseURL = credentials.baseURL ?? defaultBaseURL
        var request = URLRequest(url: baseURL.appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: CleanupPrompt.system(vocabulary: cleanup.vocabulary, styleInstruction: cleanup.styleInstruction)),
                .init(role: "user", content: cleanup.transcript)
            ],
            temperature: 0,
            responseFormat: .init(type: "json_object")
        )
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await transport.data(for: request)
        try HTTPHelpers.requireSuccess(data: data, response: response)
        let payload = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = payload.choices.first?.message.content,
              let contentData = content.data(using: .utf8),
              let cleaned = try? JSONDecoder().decode(CleanedPayload.self, from: contentData) else {
            throw ProviderError.invalidResponse
        }
        try CleanupSafetyValidator.validate(raw: cleanup.transcript, cleaned: cleaned.text, vocabulary: cleanup.vocabulary)
        return CleanupResult(
            text: cleaned.text.trimmingCharacters(in: .whitespacesAndNewlines),
            provider: metadata.kind,
            model: model,
            inputTokens: payload.usage?.promptTokens,
            outputTokens: payload.usage?.completionTokens,
            latency: seconds(since: started)
        )
    }

    private struct ModelsResponse: Decodable { let data: [Model]; struct Model: Decodable { let id: String } }
    private struct ChatRequest: Encodable {
        let model: String
        let messages: [Message]
        let temperature: Double
        let responseFormat: ResponseFormat
        enum CodingKeys: String, CodingKey { case model, messages, temperature; case responseFormat = "response_format" }
        struct Message: Encodable { let role: String; let content: String }
        struct ResponseFormat: Encodable { let type: String }
    }
    private struct ChatResponse: Decodable {
        let choices: [Choice]
        let usage: Usage?
        struct Choice: Decodable { let message: Message }
        struct Message: Decodable { let content: String }
        struct Usage: Decodable {
            let promptTokens: Int?
            let completionTokens: Int?
            enum CodingKeys: String, CodingKey { case promptTokens = "prompt_tokens"; case completionTokens = "completion_tokens" }
        }
    }
    private struct CleanedPayload: Decodable { let text: String }
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
