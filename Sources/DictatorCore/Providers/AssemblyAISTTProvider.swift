import Foundation

public struct AssemblyAISTTProvider: SpeechToTextProvider {
    public let metadata = STTProviderMetadata(
        kind: .assemblyAI,
        displayName: "AssemblyAI",
        modality: .both,
        defaultModel: "universal-3-pro",
        models: ["universal-3-pro", "universal-2"],
        supportsVocabulary: true,
        supportsLanguageDetection: true,
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
        var request = URLRequest(url: URL(string: "https://api.assemblyai.com/v2/transcript?limit=1")!)
        request.setValue(credentials.apiKey, forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.data(for: request)
        try HTTPHelpers.requireSuccess(data: data, response: response)
    }

    public func transcribe(audio: RecordedAudio, options: TranscriptionOptions, credentials: ProviderCredentials) async throws -> TranscriptionResult {
        let started = ContinuousClock.now
        var upload = URLRequest(url: URL(string: "https://api.assemblyai.com/v2/upload")!)
        upload.httpMethod = "POST"
        upload.setValue(credentials.apiKey, forHTTPHeaderField: "Authorization")
        upload.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        upload.httpBody = audio.wavData
        let (uploadData, uploadResponse) = try await transport.data(for: upload)
        try HTTPHelpers.requireSuccess(data: uploadData, response: uploadResponse)
        let uploadPayload = try JSONDecoder().decode(UploadResponse.self, from: uploadData)

        var payload: [String: Any] = ["audio_url": uploadPayload.uploadURL, "speech_models": [options.model], "format_text": true]
        if let language = options.language { payload["language_code"] = language }
        let terms = options.vocabulary.filter(\.isEnabled).map(\.value)
        if !terms.isEmpty { payload["keyterms_prompt"] = Array(terms.prefix(1_000)) }
        var create = URLRequest(url: URL(string: "https://api.assemblyai.com/v2/transcript")!)
        create.httpMethod = "POST"
        create.setValue(credentials.apiKey, forHTTPHeaderField: "Authorization")
        create.setValue("application/json", forHTTPHeaderField: "Content-Type")
        create.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (createData, createResponse) = try await transport.data(for: create)
        try HTTPHelpers.requireSuccess(data: createData, response: createResponse)
        let created = try JSONDecoder().decode(JobResponse.self, from: createData)

        for _ in 0..<240 {
            var poll = URLRequest(url: URL(string: "https://api.assemblyai.com/v2/transcript/\(created.id)")!)
            poll.setValue(credentials.apiKey, forHTTPHeaderField: "Authorization")
            let (data, response) = try await transport.data(for: poll)
            try HTTPHelpers.requireSuccess(data: data, response: response)
            let job = try JSONDecoder().decode(JobResponse.self, from: data)
            if job.status == "completed" {
                let text = (job.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw ProviderError.emptyTranscript }
                return TranscriptionResult(text: text, language: job.languageCode, provider: .assemblyAI, model: options.model, requestID: job.id, latency: seconds(since: started))
            }
            if job.status == "error" { throw ProviderError.httpStatus(422, job.error ?? "Transcription failed") }
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        throw ProviderError.httpStatus(408, "Transcription timed out")
    }

    private struct UploadResponse: Decodable {
        let uploadURL: String
        enum CodingKeys: String, CodingKey { case uploadURL = "upload_url" }
    }
    private struct JobResponse: Decodable {
        let id: String
        let status: String
        let text: String?
        let error: String?
        let languageCode: String?
        enum CodingKeys: String, CodingKey { case id, status, text, error; case languageCode = "language_code" }
    }
}
