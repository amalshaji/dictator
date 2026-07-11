import Foundation

public struct GeminiCleanupProvider: CleanupLLMProvider {
    public let metadata = ProviderMetadata(
        kind: .gemini,
        displayName: "Google Gemini",
        defaultModel: "gemini-2.5-flash-lite",
        models: ["gemini-2.5-flash-lite"],
        requiresAccountID: false
    )

    private let transport: any HTTPTransport
    public init(transport: any HTTPTransport = URLSessionTransport()) { self.transport = transport }

    public func validate(credentials: ProviderCredentials) async throws { _ = try await listModels(credentials: credentials) }

    public func listModels(credentials: ProviderCredentials) async throws -> [String] {
        guard !credentials.apiKey.isEmpty else { throw ProviderError.missingCredential("API key") }
        var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models")!
        components.queryItems = [URLQueryItem(name: "key", value: credentials.apiKey)]
        guard let url = components.url else { throw ProviderError.invalidConfiguration("The Gemini API key is invalid.") }
        let (data, response) = try await transport.data(for: URLRequest(url: url))
        try HTTPHelpers.requireSuccess(data: data, response: response)
        let payload = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return payload.models.map { $0.name.replacingOccurrences(of: "models/", with: "") }.sorted()
    }

    public func clean(request cleanup: CleanupRequest, model: String, credentials: ProviderCredentials) async throws -> CleanupResult {
        let started = ContinuousClock.now
        var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        components.queryItems = [URLQueryItem(name: "key", value: credentials.apiKey)]
        guard let url = components.url else { throw ProviderError.invalidConfiguration("The Gemini model name is invalid.") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = RequestBody(
            systemInstruction: .init(parts: [.init(text: CleanupPrompt.system(vocabulary: cleanup.vocabulary, styleInstruction: cleanup.styleInstruction))]),
            contents: [.init(role: "user", parts: [.init(text: try CleanupPrompt.user(request: cleanup))])],
            generationConfig: .init(temperature: 0, responseMimeType: "application/json")
        )
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await transport.data(for: request)
        try HTTPHelpers.requireSuccess(data: data, response: response)
        let payload = try JSONDecoder().decode(ResponseBody.self, from: data)
        guard let content = payload.candidates.first?.content.parts.first?.text,
              let contentData = content.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(CleanedPayload.self, from: contentData) else {
            throw ProviderError.invalidResponse
        }
        try CleanupSafetyValidator.validate(request: cleanup, intent: parsed.intent, cleaned: parsed.text)
        return CleanupResult(
            text: parsed.text,
            intent: parsed.intent,
            provider: .gemini,
            model: model,
            inputTokens: payload.usageMetadata?.promptTokenCount,
            outputTokens: payload.usageMetadata?.candidatesTokenCount,
            latency: seconds(since: started)
        )
    }

    private struct ModelsResponse: Decodable { let models: [Model]; struct Model: Decodable { let name: String } }
    private struct RequestBody: Encodable {
        let systemInstruction: Content
        let contents: [Content]
        let generationConfig: GenerationConfig
        struct Content: Encodable { let role: String?; let parts: [Part]; init(role: String? = nil, parts: [Part]) { self.role = role; self.parts = parts } }
        struct Part: Encodable { let text: String }
        struct GenerationConfig: Encodable { let temperature: Double; let responseMimeType: String }
    }
    private struct ResponseBody: Decodable {
        let candidates: [Candidate]
        let usageMetadata: Usage?
        struct Candidate: Decodable { let content: Content }
        struct Content: Decodable { let parts: [Part] }
        struct Part: Decodable { let text: String? }
        struct Usage: Decodable { let promptTokenCount: Int?; let candidatesTokenCount: Int? }
    }
    private struct CleanedPayload: Decodable { let intent: CleanupIntent; let text: String }
}
