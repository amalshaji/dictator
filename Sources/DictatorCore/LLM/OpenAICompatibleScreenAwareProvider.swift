import Foundation

public struct OpenAICompatibleScreenAwareProvider: ScreenAwareLLMProvider {
    public let metadata: ProviderMetadata
    private let defaultBaseURL: URL
    private let transport: any HTTPTransport

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
        self.defaultBaseURL = defaultBaseURL
        self.transport = transport
    }

    public func validate(credentials: ProviderCredentials) async throws {
        _ = try await listModels(credentials: credentials)
    }

    public func listModels(credentials: ProviderCredentials) async throws -> [String] {
        guard !credentials.apiKey.isEmpty else { throw ProviderError.missingCredential("API key") }
        var request = URLRequest(url: try resolvedBaseURL(credentials).appending(path: "models"))
        request.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.data(for: request)
        try HTTPHelpers.requireSuccess(data: data, response: response)
        return try JSONDecoder().decode(ModelsResponse.self, from: data).data.map(\.id).sorted()
    }

    public func generate(
        request screenAware: ScreenAwareRequest,
        model: String,
        credentials: ProviderCredentials
    ) async throws -> ScreenAwareResult {
        guard !credentials.apiKey.isEmpty else { throw ProviderError.missingCredential("API key") }
        let started = ContinuousClock.now
        var request = URLRequest(url: try resolvedBaseURL(credentials).appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let imageURL = "data:\(screenAware.imageMIMEType);base64,\(screenAware.imageData.base64EncodedString())"
        request.httpBody = try JSONEncoder().encode(ChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: .text(ScreenAwarePrompt.system)),
                .init(role: "user", content: .parts([
                    .init(type: "text", text: try ScreenAwarePrompt.user(request: screenAware)),
                    .init(type: "image_url", imageURL: .init(url: imageURL))
                ]))
            ],
            temperature: 0,
            responseFormat: .init(type: "json_object")
        ))
        let (data, response) = try await transport.data(for: request)
        try HTTPHelpers.requireSuccess(data: data, response: response)
        let payload = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = payload.choices.first?.message.content else { throw ProviderError.invalidResponse }
        let (intent, text) = try ScreenAwareResponseDecoder.decode(content, selectedText: screenAware.selectedText)
        return ScreenAwareResult(
            intent: intent,
            text: text,
            provider: metadata.kind,
            model: model,
            inputTokens: payload.usage?.promptTokens,
            outputTokens: payload.usage?.completionTokens,
            providerReportedCostUSD: payload.usage?.cost.map { Decimal($0) },
            latency: seconds(since: started)
        )
    }

    private func resolvedBaseURL(_ credentials: ProviderCredentials) throws -> URL {
        if metadata.kind == .openAICompatible, credentials.baseURL == nil {
            throw ProviderError.missingCredential("base URL")
        }
        let url = credentials.baseURL ?? defaultBaseURL
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            throw ProviderError.invalidConfiguration("Enter a valid HTTP or HTTPS base URL.")
        }
        return url
    }

    private struct ModelsResponse: Decodable {
        let data: [Model]
        struct Model: Decodable { let id: String }
    }

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [Message]
        let temperature: Double
        let responseFormat: ResponseFormat
        enum CodingKeys: String, CodingKey { case model, messages, temperature; case responseFormat = "response_format" }

        struct Message: Encodable {
            let role: String
            let content: Content
        }

        enum Content: Encodable {
            case text(String)
            case parts([Part])

            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .text(let value): try container.encode(value)
                case .parts(let value): try container.encode(value)
                }
            }
        }

        struct Part: Encodable {
            let type: String
            let text: String?
            let imageURL: ImageURL?
            enum CodingKeys: String, CodingKey { case type, text; case imageURL = "image_url" }

            init(type: String, text: String? = nil, imageURL: ImageURL? = nil) {
                self.type = type
                self.text = text
                self.imageURL = imageURL
            }
        }

        struct ImageURL: Encodable { let url: String }
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
            let cost: Double?
            enum CodingKeys: String, CodingKey { case promptTokens = "prompt_tokens"; case completionTokens = "completion_tokens"; case cost }
        }
    }
}

public extension OpenAICompatibleScreenAwareProvider {
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
