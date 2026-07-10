import Foundation

public struct XAISTTProvider: SpeechToTextProvider {
    public let metadata = STTProviderMetadata(
        kind: .xAI,
        displayName: "xAI",
        modality: .both,
        defaultModel: "grok-transcribe",
        models: ["grok-transcribe"],
        supportsVocabulary: true,
        supportsLanguageDetection: false,
        requiresAccountID: false
    )

    private let transport: any HTTPTransport
    public init(transport: any HTTPTransport = URLSessionTransport()) { self.transport = transport }

    public func validate(credentials: ProviderCredentials) async throws {
        guard !credentials.apiKey.isEmpty else { throw ProviderError.missingCredential("API key") }
        var request = URLRequest(url: URL(string: "https://api.x.ai/v1/models")!)
        request.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.data(for: request)
        try HTTPHelpers.requireSuccess(data: data, response: response)
    }

    public func transcribe(audio: RecordedAudio, options: TranscriptionOptions, credentials: ProviderCredentials) async throws -> TranscriptionResult {
        let started = ContinuousClock.now
        let boundary = "dictator-\(UUID().uuidString)"
        var fields: [(String, String)] = [("format", "true")]
        if let language = options.language { fields.append(("language", language)) }
        fields += options.vocabulary.filter(\.isEnabled).prefix(100).map { ("keyterm", String($0.value.prefix(50))) }
        var request = URLRequest(url: URL(string: "https://api.x.ai/v1/stt")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = HTTPHelpers.multipartBody(fields: fields, fileField: "file", filename: "dictation.wav", mimeType: "audio/wav", fileData: audio.wavData, boundary: boundary)
        let (data, response) = try await transport.data(for: request)
        try HTTPHelpers.requireSuccess(data: data, response: response)
        let payload = try JSONDecoder().decode(Response.self, from: data)
        let text = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ProviderError.emptyTranscript }
        return TranscriptionResult(text: text, language: payload.language, provider: .xAI, model: options.model, latency: seconds(since: started))
    }

    private struct Response: Decodable { let text: String; let language: String? }
}
