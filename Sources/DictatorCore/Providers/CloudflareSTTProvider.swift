import Foundation

public struct CloudflareSTTProvider: SpeechToTextProvider {
    public let metadata = STTProviderMetadata(
        kind: .cloudflare,
        displayName: "Cloudflare Workers AI",
        modality: .batch,
        defaultModel: "@cf/openai/whisper-large-v3-turbo",
        models: ["@cf/openai/whisper-large-v3-turbo", "@cf/openai/whisper"],
        supportsVocabulary: true,
        supportsLanguageDetection: true,
        requiresAccountID: true
    )

    private let transport: any HTTPTransport
    public init(transport: any HTTPTransport = URLSessionTransport()) { self.transport = transport }

    public func validate(credentials: ProviderCredentials) async throws {
        guard !credentials.apiKey.isEmpty else { throw ProviderError.missingCredential("API token") }
        guard let accountID = credentials.accountID, !accountID.isEmpty else { throw ProviderError.missingCredential("account ID") }
        var request = URLRequest(url: URL(string: "https://api.cloudflare.com/client/v4/accounts/\(accountID)/ai/models/search")!)
        request.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.data(for: request)
        try HTTPHelpers.requireSuccess(data: data, response: response)
    }

    public func transcribe(audio: RecordedAudio, options: TranscriptionOptions, credentials: ProviderCredentials) async throws -> TranscriptionResult {
        guard let accountID = credentials.accountID, !accountID.isEmpty else { throw ProviderError.missingCredential("account ID") }
        let started = ContinuousClock.now
        let endpoint = "https://api.cloudflare.com/client/v4/accounts/\(accountID)/ai/run/\(options.model)"
        var body: [String: Any] = ["audio": audio.wavData.base64EncodedString(), "vad_filter": true]
        if let language = options.language { body["language"] = language }
        let vocabulary = options.vocabulary.filter(\.isEnabled).map(\.value).joined(separator: ", ")
        if !vocabulary.isEmpty { body["initial_prompt"] = vocabulary }

        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await transport.data(for: request)
        try HTTPHelpers.requireSuccess(data: data, response: response)
        let payload = try JSONDecoder().decode(Envelope.self, from: data)
        guard payload.success != false else { throw ProviderError.invalidResponse }
        let text = payload.result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ProviderError.emptyTranscript }
        return TranscriptionResult(text: text, provider: .cloudflare, model: options.model, latency: seconds(since: started))
    }

    private struct Envelope: Decodable {
        let success: Bool?
        let result: Result
        struct Result: Decodable { let text: String }
    }
}

