import Foundation

struct LLMWireResult: Sendable {
    let content: String
    let inputTokens: Int?
    let outputTokens: Int?
    let latency: TimeInterval
}

enum OpenAIChatContent: Encodable, Sendable {
    case text(String)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let value): try container.encode(value)
        }
    }
}

struct OpenAIChatMessage: Encodable, Sendable {
    let role: String
    let content: OpenAIChatContent
}

struct OpenAICompatibleClient: Sendable {
    let kind: ProviderKind
    let defaultBaseURL: URL
    let transport: any HTTPTransport

    func validate(credentials: ProviderCredentials) async throws {
        _ = try await listModels(credentials: credentials)
    }

    func listModels(credentials: ProviderCredentials) async throws -> [String] {
        guard !credentials.apiKey.isEmpty else { throw ProviderError.missingCredential("API key") }
        var request = URLRequest(url: try resolvedBaseURL(credentials).appending(path: "models"))
        request.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.data(for: request)
        try HTTPHelpers.requireSuccess(data: data, response: response)
        return try JSONDecoder().decode(ModelsResponse.self, from: data).data.map(\.id).sorted()
    }

    func warmUpConnection(credentials: ProviderCredentials) async {
        guard let url = try? resolvedBaseURL(credentials) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        _ = try? await transport.data(for: request)
    }

    func complete(
        model: String,
        messages: [OpenAIChatMessage],
        credentials: ProviderCredentials
    ) async throws -> LLMWireResult {
        guard !credentials.apiKey.isEmpty else { throw ProviderError.missingCredential("API key") }
        let started = ContinuousClock.now
        var request = URLRequest(url: try resolvedBaseURL(credentials).appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ChatRequest(
            model: model,
            messages: messages,
            temperature: 0,
            responseFormat: .init(type: "json_object"),
            reasoningEffort: Self.reasoningEffort(kind: kind, model: model)
        ))
        let (data, response) = try await transport.data(for: request)
        try HTTPHelpers.requireSuccess(data: data, response: response)
        let payload = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = payload.choices.first?.message.content else { throw ProviderError.invalidResponse }
        return LLMWireResult(
            content: content,
            inputTokens: payload.usage?.promptTokens,
            outputTokens: payload.usage?.completionTokens,
            latency: seconds(since: started)
        )
    }

    /// gpt-oss models reason at "medium" effort by default, spending hundreds of
    /// hidden tokens before the JSON answer. "low" cuts that without hurting a
    /// short rewrite task. Only Groq and Cerebras document this parameter.
    private static func reasoningEffort(kind: ProviderKind, model: String) -> String? {
        guard kind == .groq || kind == .cerebras else { return nil }
        return model.contains("gpt-oss") ? "low" : nil
    }

    private func resolvedBaseURL(_ credentials: ProviderCredentials) throws -> URL {
        if kind == .openAICompatible, credentials.baseURL == nil {
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
        let messages: [OpenAIChatMessage]
        let temperature: Double
        let responseFormat: ResponseFormat
        let reasoningEffort: String?

        private enum CodingKeys: String, CodingKey {
            case model, messages, temperature
            case responseFormat = "response_format"
            case reasoningEffort = "reasoning_effort"
        }

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
            private enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens"
                case completionTokens = "completion_tokens"
            }
        }
    }
}
