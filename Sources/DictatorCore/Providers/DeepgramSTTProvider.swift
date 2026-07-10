import Foundation

public struct DeepgramSTTProvider: SpeechToTextProvider {
    public let metadata = ProviderMetadata(
        kind: .deepgram,
        displayName: "Deepgram",
        defaultModel: "nova-3",
        models: ["nova-3", "nova-3-general"],
        requiresAccountID: false
    )

    private let transport: any HTTPTransport
    public init(transport: any HTTPTransport = URLSessionTransport()) { self.transport = transport }

    public func validate(credentials: ProviderCredentials) async throws {
        guard !credentials.apiKey.isEmpty else { throw ProviderError.missingCredential("API key") }
        var request = URLRequest(url: URL(string: "https://api.deepgram.com/v1/projects")!)
        request.setValue("Token \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.data(for: request)
        try HTTPHelpers.requireSuccess(data: data, response: response)
    }

    public func transcribe(audio: RecordedAudio, options: TranscriptionOptions, credentials: ProviderCredentials) async throws -> TranscriptionResult {
        let started = ContinuousClock.now
        var components = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        var query = [URLQueryItem(name: "model", value: options.model), URLQueryItem(name: "smart_format", value: "true")]
        if let language = options.language {
            query.append(URLQueryItem(name: "language", value: language))
        } else {
            query.append(URLQueryItem(name: "detect_language", value: "true"))
        }
        query += options.vocabulary.filter(\.isEnabled).map { URLQueryItem(name: "keyterm", value: $0.value) }
        components.queryItems = query
        guard let url = components.url else { throw ProviderError.invalidConfiguration("The Deepgram request options are invalid.") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Token \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.httpBody = audio.wavData
        let (data, response) = try await transport.data(for: request)
        try HTTPHelpers.requireSuccess(data: data, response: response)
        let payload = try JSONDecoder().decode(Response.self, from: data)
        guard let channel = payload.results.channels.first,
              let alternative = channel.alternatives.first
        else { throw ProviderError.invalidResponse }
        let text = alternative.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ProviderError.emptyTranscript }
        return TranscriptionResult(
            text: text,
            language: channel.detectedLanguage ?? alternative.languages?.first ?? options.language,
            provider: .deepgram,
            model: options.model,
            requestID: payload.metadata?.requestID,
            latency: seconds(since: started)
        )
    }

    private struct Response: Decodable {
        let metadata: Metadata?
        let results: Results
        struct Metadata: Decodable {
            let requestID: String?
            enum CodingKeys: String, CodingKey { case requestID = "request_id" }
        }
        struct Results: Decodable { let channels: [Channel] }
        struct Channel: Decodable {
            let alternatives: [Alternative]
            let detectedLanguage: String?
            enum CodingKeys: String, CodingKey {
                case alternatives
                case detectedLanguage = "detected_language"
            }
        }
        struct Alternative: Decodable { let transcript: String; let languages: [String]? }
    }
}
