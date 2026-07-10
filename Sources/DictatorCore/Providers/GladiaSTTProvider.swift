import Foundation

public struct GladiaSTTProvider: SpeechToTextProvider {
    public let metadata = ProviderMetadata(
        kind: .gladia,
        displayName: "Gladia",
        defaultModel: "solaria-1",
        models: ["solaria-1"],
        requiresAccountID: false
    )

    private let transport: any HTTPTransport
    private let pollIntervalNanoseconds: UInt64
    public init(transport: any HTTPTransport = URLSessionTransport(), pollIntervalNanoseconds: UInt64 = 500_000_000) {
        self.transport = transport
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
    }

    public func validate(credentials: ProviderCredentials) async throws {
        guard !credentials.apiKey.isEmpty else { throw ProviderError.missingCredential("API key") }
    }

    public func transcribe(audio: RecordedAudio, options: TranscriptionOptions, credentials: ProviderCredentials) async throws -> TranscriptionResult {
        let started = ContinuousClock.now
        let boundary = "dictator-\(UUID().uuidString)"
        var upload = URLRequest(url: URL(string: "https://api.gladia.io/v2/upload")!)
        upload.httpMethod = "POST"
        upload.setValue(credentials.apiKey, forHTTPHeaderField: "x-gladia-key")
        upload.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        upload.httpBody = HTTPHelpers.multipartBody(fields: [:], fileField: "audio", filename: "dictation.wav", mimeType: "audio/wav", fileData: audio.wavData, boundary: boundary)
        let (uploadData, uploadResponse) = try await transport.data(for: upload)
        try HTTPHelpers.requireSuccess(data: uploadData, response: uploadResponse)
        let uploaded = try JSONDecoder().decode(UploadResponse.self, from: uploadData)

        // Gladia selects the current Solaria engine server-side; `model` is not a v2 request field.
        var body: [String: Any] = ["audio_url": uploaded.audioURL, "enhanced_punctuation": true]
        if let language = options.language { body["language_config"] = ["languages": [language], "code_switching": false] }
        let terms = options.vocabulary.filter(\.isEnabled).map(\.value)
        if !terms.isEmpty {
            body["custom_vocabulary"] = true
            body["custom_vocabulary_config"] = ["vocabulary": terms]
        }
        var create = URLRequest(url: URL(string: "https://api.gladia.io/v2/pre-recorded")!)
        create.httpMethod = "POST"
        create.setValue(credentials.apiKey, forHTTPHeaderField: "x-gladia-key")
        create.setValue("application/json", forHTTPHeaderField: "Content-Type")
        create.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (createData, createResponse) = try await transport.data(for: create)
        try HTTPHelpers.requireSuccess(data: createData, response: createResponse)
        let created = try JSONDecoder().decode(CreateResponse.self, from: createData)

        for _ in 0..<240 {
            var poll = URLRequest(url: try HTTPHelpers.requireHTTPURL(created.resultURL))
            poll.setValue(credentials.apiKey, forHTTPHeaderField: "x-gladia-key")
            let (data, response) = try await transport.data(for: poll)
            try HTTPHelpers.requireSuccess(data: data, response: response)
            let job = try JSONDecoder().decode(JobResponse.self, from: data)
            if job.status == "done" {
                let text = (job.result?.transcription.fullTranscript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw ProviderError.emptyTranscript }
                return TranscriptionResult(text: text, provider: .gladia, model: options.model, requestID: created.id, latency: seconds(since: started))
            }
            if job.status == "error" { throw ProviderError.httpStatus(422, "Gladia transcription failed") }
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        throw ProviderError.httpStatus(408, "Transcription timed out")
    }

    private struct UploadResponse: Decodable {
        let audioURL: String
        enum CodingKeys: String, CodingKey { case audioURL = "audio_url" }
    }
    private struct CreateResponse: Decodable {
        let id: String
        let resultURL: String
        enum CodingKeys: String, CodingKey { case id; case resultURL = "result_url" }
    }
    private struct JobResponse: Decodable {
        let status: String
        let result: Result?
        struct Result: Decodable { let transcription: Transcription }
        struct Transcription: Decodable {
            let fullTranscript: String
            enum CodingKeys: String, CodingKey { case fullTranscript = "full_transcript" }
        }
    }
}
