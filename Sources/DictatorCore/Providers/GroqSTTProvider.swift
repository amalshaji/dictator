import Foundation

public struct GroqSTTProvider: SpeechToTextProvider {
    public let metadata = ProviderMetadata(
        kind: .groq,
        displayName: "Groq",
        defaultModel: "whisper-large-v3-turbo",
        models: ["whisper-large-v3-turbo", "whisper-large-v3"],
        requiresAccountID: false
    )

    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    public func validate(credentials: ProviderCredentials) async throws {
        guard !credentials.apiKey.isEmpty else { throw ProviderError.missingCredential("API key") }
        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/models")!)
        request.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.data(for: request)
        try HTTPHelpers.requireSuccess(data: data, response: response)
    }

    public func transcribe(audio: RecordedAudio, options: TranscriptionOptions, credentials: ProviderCredentials) async throws -> TranscriptionResult {
        let started = ContinuousClock.now
        let boundary = "dictator-\(UUID().uuidString)"
        var fields = ["model": options.model, "response_format": "json", "temperature": "0"]
        if let language = options.language { fields["language"] = language }
        let prompt = options.vocabulary.filter(\.isEnabled).map(\.value).joined(separator: ", ")
        if !prompt.isEmpty { fields["prompt"] = String(prompt.prefix(900)) }

        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = HTTPHelpers.multipartBody(
            fields: fields,
            fileField: "file",
            filename: "dictation.wav",
            mimeType: "audio/wav",
            fileData: audio.wavData,
            boundary: boundary
        )

        let (data, response) = try await transport.data(for: request)
        try HTTPHelpers.requireSuccess(data: data, response: response)
        let payload = try JSONDecoder().decode(Response.self, from: data)
        let text = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ProviderError.emptyTranscript }
        return TranscriptionResult(
            text: text,
            provider: .groq,
            model: options.model,
            requestID: payload.xGroq?.id,
            latency: seconds(since: started)
        )
    }

    private struct Response: Decodable {
        let text: String
        let xGroq: GroqMetadata?

        enum CodingKeys: String, CodingKey { case text; case xGroq = "x_groq" }
        struct GroqMetadata: Decodable { let id: String? }
    }
}
