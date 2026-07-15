import Foundation

struct LLMWireResult: Sendable {
    let content: String
    let inputTokens: Int?
    let outputTokens: Int?
    let providerReportedCostUSD: Decimal?
    let latency: TimeInterval
}

enum OpenAIChatContent: Encodable, Sendable {
    case text(String)
    case parts([OpenAIChatPart])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let value): try container.encode(value)
        case .parts(let value): try container.encode(value)
        }
    }
}

struct OpenAIChatPart: Encodable, Sendable {
    let type: String
    let text: String?
    let imageURL: ImageURL?

    struct ImageURL: Encodable, Sendable { let url: String }

    init(type: String, text: String? = nil, imageURL: ImageURL? = nil) {
        self.type = type
        self.text = text
        self.imageURL = imageURL
    }

    private enum CodingKeys: String, CodingKey {
        case type, text
        case imageURL = "image_url"
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
            responseFormat: .init(type: "json_object")
        ))
        let (data, response) = try await transport.data(for: request)
        try HTTPHelpers.requireSuccess(data: data, response: response)
        let payload = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = payload.choices.first?.message.content else { throw ProviderError.invalidResponse }
        return LLMWireResult(
            content: content,
            inputTokens: payload.usage?.promptTokens,
            outputTokens: payload.usage?.completionTokens,
            providerReportedCostUSD: payload.usage?.cost.map { Decimal($0) },
            latency: seconds(since: started)
        )
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

        private enum CodingKeys: String, CodingKey {
            case model, messages, temperature
            case responseFormat = "response_format"
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
            let cost: Double?
            private enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens"
                case completionTokens = "completion_tokens"
                case cost
            }
        }
    }
}

struct GeminiPart: Encodable, Sendable {
    let text: String?
    let inlineData: InlineData?

    struct InlineData: Encodable, Sendable {
        let mimeType: String
        let data: String
    }

    init(text: String? = nil, inlineData: InlineData? = nil) {
        self.text = text
        self.inlineData = inlineData
    }
}

struct GeminiClient: Sendable {
    let transport: any HTTPTransport

    func validate(credentials: ProviderCredentials) async throws {
        _ = try await listModels(credentials: credentials)
    }

    func listModels(credentials: ProviderCredentials) async throws -> [String] {
        guard !credentials.apiKey.isEmpty else { throw ProviderError.missingCredential("API key") }
        var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models")!
        components.queryItems = [URLQueryItem(name: "key", value: credentials.apiKey)]
        guard let url = components.url else {
            throw ProviderError.invalidConfiguration("The Gemini API key is invalid.")
        }
        let (data, response) = try await transport.data(for: URLRequest(url: url))
        try HTTPHelpers.requireSuccess(data: data, response: response)
        return try JSONDecoder().decode(ModelsResponse.self, from: data).models
            .map { $0.name.replacingOccurrences(of: "models/", with: "") }
            .sorted()
    }

    func generate(
        model: String,
        systemPrompt: String,
        userParts: [GeminiPart],
        credentials: ProviderCredentials
    ) async throws -> LLMWireResult {
        guard !credentials.apiKey.isEmpty else { throw ProviderError.missingCredential("API key") }
        let started = ContinuousClock.now
        var components = URLComponents(
            string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        )!
        components.queryItems = [URLQueryItem(name: "key", value: credentials.apiKey)]
        guard let url = components.url else {
            throw ProviderError.invalidConfiguration("The Gemini model name is invalid.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RequestBody(
            systemInstruction: .init(parts: [.init(text: systemPrompt)]),
            contents: [.init(role: "user", parts: userParts)],
            generationConfig: .init(temperature: 0, responseMimeType: "application/json")
        ))
        let (data, response) = try await transport.data(for: request)
        try HTTPHelpers.requireSuccess(data: data, response: response)
        let payload = try JSONDecoder().decode(ResponseBody.self, from: data)
        guard let content = payload.candidates.first?.content.parts.first?.text else {
            throw ProviderError.invalidResponse
        }
        return LLMWireResult(
            content: content,
            inputTokens: payload.usageMetadata?.promptTokenCount,
            outputTokens: payload.usageMetadata?.candidatesTokenCount,
            providerReportedCostUSD: nil,
            latency: seconds(since: started)
        )
    }

    private struct ModelsResponse: Decodable {
        let models: [Model]
        struct Model: Decodable { let name: String }
    }

    private struct RequestBody: Encodable {
        let systemInstruction: Content
        let contents: [Content]
        let generationConfig: GenerationConfig
        struct Content: Encodable {
            let role: String?
            let parts: [GeminiPart]
            init(role: String? = nil, parts: [GeminiPart]) {
                self.role = role
                self.parts = parts
            }
        }
        struct GenerationConfig: Encodable {
            let temperature: Double
            let responseMimeType: String
        }
    }

    private struct ResponseBody: Decodable {
        let candidates: [Candidate]
        let usageMetadata: Usage?
        struct Candidate: Decodable { let content: Content }
        struct Content: Decodable { let parts: [Part] }
        struct Part: Decodable { let text: String? }
        struct Usage: Decodable {
            let promptTokenCount: Int?
            let candidatesTokenCount: Int?
        }
    }
}
