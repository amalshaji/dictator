import Foundation

public struct CloudflareCleanupProvider: CleanupLLMProvider {
    public let metadata = ProviderMetadata(
        kind: .cloudflare,
        displayName: "Cloudflare Workers AI",
        defaultModel: "@cf/qwen/qwen3-30b-a3b-fp8",
        models: ["@cf/qwen/qwen3-30b-a3b-fp8"],
        requiresAccountID: true
    )

    private let transport: any HTTPTransport
    public init(transport: any HTTPTransport = URLSessionTransport()) { self.transport = transport }

    public func validate(credentials: ProviderCredentials) async throws {
        guard !credentials.apiKey.isEmpty else { throw ProviderError.missingCredential("API token") }
        guard let accountID = credentials.accountID, !accountID.isEmpty else { throw ProviderError.missingCredential("account ID") }
        let url = try HTTPHelpers.requireHTTPURL("https://api.cloudflare.com/client/v4/accounts/\(accountID)/ai/models/search")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.data(for: request)
        try HTTPHelpers.requireSuccess(data: data, response: response)
    }

    public func listModels(credentials: ProviderCredentials) async throws -> [String] {
        [metadata.defaultModel, "@cf/openai/gpt-oss-20b", "@cf/openai/gpt-oss-120b"]
    }

    public func clean(request cleanup: CleanupRequest, model: String, credentials: ProviderCredentials) async throws -> CleanupResult {
        guard let accountID = credentials.accountID, !accountID.isEmpty else { throw ProviderError.missingCredential("account ID") }
        let started = ContinuousClock.now
        let url = try HTTPHelpers.requireHTTPURL("https://api.cloudflare.com/client/v4/accounts/\(accountID)/ai/run/\(model)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = RequestBody(
            messages: [
                .init(role: "system", content: CleanupPrompt.system(vocabulary: cleanup.vocabulary, styleInstruction: cleanup.styleInstruction)),
                .init(role: "user", content: cleanup.transcript)
            ],
            responseFormat: .init(type: "json_object"),
            temperature: 0
        )
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await transport.data(for: request)
        try HTTPHelpers.requireSuccess(data: data, response: response)
        let payload = try JSONDecoder().decode(Envelope.self, from: data)
        let content = payload.result.response ?? payload.result.text ?? ""
        guard let contentData = content.data(using: .utf8), let parsed = try? JSONDecoder().decode(CleanedPayload.self, from: contentData) else {
            throw ProviderError.invalidResponse
        }
        try CleanupSafetyValidator.validate(raw: cleanup.transcript, cleaned: parsed.text, vocabulary: cleanup.vocabulary)
        return CleanupResult(text: parsed.text, provider: .cloudflare, model: model, latency: seconds(since: started))
    }

    private struct RequestBody: Encodable {
        let messages: [Message]
        let responseFormat: ResponseFormat
        let temperature: Double
        enum CodingKeys: String, CodingKey { case messages, temperature; case responseFormat = "response_format" }
        struct Message: Encodable { let role: String; let content: String }
        struct ResponseFormat: Encodable { let type: String }
    }
    private struct Envelope: Decodable {
        let result: Result
        struct Result: Decodable { let response: String?; let text: String? }
    }
    private struct CleanedPayload: Decodable { let text: String }
}
