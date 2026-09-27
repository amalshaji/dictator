import Foundation

public enum ProviderKind: String, Codable, CaseIterable, Sendable {
    case appleSpeech = "apple-speech"
    case groq
    case deepgram
    case gemini
    case cerebras
    case openRouter = "openrouter"
    case openAICompatible = "openai-compatible"

    public var displayName: String {
        ProviderRegistry.sttMetadata(includeAppleSpeech: true).first { $0.kind == self }?.displayName
            ?? CleanupProviderRegistry.metadata.first { $0.kind == self }?.displayName
            ?? rawValue
    }
}

public enum AppleTranscriptionEngine: String, Codable, Equatable, Sendable {
    case speechTranscriber = "speech-transcriber"
    case dictationTranscriber = "dictation-transcriber"
}

public struct AppleSpeechLocale: Identifiable, Codable, Equatable, Sendable {
    public let identifier: String
    public let engine: AppleTranscriptionEngine

    public var id: String { identifier }

    public init(identifier: String, engine: AppleTranscriptionEngine) {
        self.identifier = identifier
        self.engine = engine
    }
}

public enum AppleSpeechReadiness: Equatable, Sendable {
    case checking
    case downloadRequired(AppleSpeechLocale)
    case downloading(AppleSpeechLocale, progress: Double)
    case ready(AppleSpeechLocale)
    case unavailable(String)
    case failed(String)

    public var locale: AppleSpeechLocale? {
        switch self {
        case .downloadRequired(let locale), .downloading(let locale, _), .ready(let locale): locale
        case .checking, .unavailable, .failed: nil
        }
    }

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

public struct ProviderCredentials: Codable, Equatable, Sendable {
    public var apiKey: String
    public var baseURL: URL?

    public init(apiKey: String, baseURL: URL? = nil) {
        self.apiKey = apiKey
        self.baseURL = baseURL
    }
}

public struct RecordedAudio: Equatable, Sendable {
    public let wavData: Data
    public let duration: TimeInterval

    public init(wavData: Data, duration: TimeInterval) {
        self.wavData = wavData
        self.duration = duration
    }
}

public enum ProviderPurpose: String, Sendable {
    case speechToText = "stt"
    case cleanup = "llm"
}

public struct VocabularyEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var value: String
    public var variants: [String]
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        value: String,
        variants: [String] = [],
        isEnabled: Bool = true
    ) {
        self.id = id
        self.value = value
        self.variants = variants
        self.isEnabled = isEnabled
    }
}

public struct WritingStyle: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var instruction: String
    public var isEnabled: Bool

    public init(id: UUID = UUID(), name: String, instruction: String, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.instruction = instruction
        self.isEnabled = isEnabled
    }
}

public struct SnippetEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var trigger: String
    public var expansion: String
    public var isEnabled: Bool

    public init(id: UUID = UUID(), trigger: String, expansion: String, isEnabled: Bool = true) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
        self.isEnabled = isEnabled
    }
}

public struct TranscriptionOptions: Equatable, Sendable {
    public var model: String
    public var language: String?
    public var vocabulary: [VocabularyEntry]

    public init(model: String, language: String? = nil, vocabulary: [VocabularyEntry] = []) {
        self.model = model
        self.language = language
        self.vocabulary = vocabulary
    }
}

public struct TranscriptionResult: Equatable, Sendable {
    public var text: String
    public var language: String?
    public var provider: ProviderKind
    public var model: String
    public var requestID: String?
    public var latency: TimeInterval

    public init(text: String, language: String? = nil, provider: ProviderKind, model: String, requestID: String? = nil, latency: TimeInterval) {
        self.text = text
        self.language = language
        self.provider = provider
        self.model = model
        self.requestID = requestID
        self.latency = latency
    }
}

public struct ProviderMetadata: Identifiable, Equatable, Sendable {
    public let kind: ProviderKind
    public let displayName: String
    public let defaultModel: String
    public let models: [String]

    public var id: ProviderKind { kind }
}

public enum CleanupInput: Equatable, Sendable {
    case transcription(String)
    case contextual(spokenText: String, selectedText: String)

    public var spokenText: String {
        switch self {
        case .transcription(let text), .contextual(let text, _): text
        }
    }
}

public struct CleanupRequest: Equatable, Sendable {
    public var input: CleanupInput
    public var vocabulary: [VocabularyEntry]
    public var styleInstruction: String?
    public var customInstruction: String?

    public init(
        input: CleanupInput,
        vocabulary: [VocabularyEntry] = [],
        styleInstruction: String? = nil,
        customInstruction: String? = nil
    ) {
        self.input = input
        self.vocabulary = vocabulary
        self.styleInstruction = styleInstruction
        self.customInstruction = customInstruction
    }
}

public enum CleanupIntent: String, Codable, Equatable, Sendable {
    case transcription
    case transformation
}

public enum CleanupOutput: Equatable, Sendable {
    case transcription(String)
    case transformation(String)

    public var text: String {
        switch self {
        case .transcription(let text), .transformation(let text): text
        }
    }

    public var intent: CleanupIntent {
        switch self {
        case .transcription: .transcription
        case .transformation: .transformation
        }
    }
}

public struct CleanupResult: Equatable, Sendable {
    public var output: CleanupOutput
    public var provider: ProviderKind
    public var model: String
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var latency: TimeInterval

    public init(
        output: CleanupOutput,
        provider: ProviderKind,
        model: String,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        latency: TimeInterval
    ) {
        self.output = output
        self.provider = provider
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.latency = latency
    }

    public var text: String { output.text }
    public var intent: CleanupIntent { output.intent }
}

public struct LLMUsage: Codable, Equatable, Sendable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public init(inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
    }
}

public struct LLMExecution: Codable, Equatable, Sendable {
    public var provider: ProviderKind
    public var model: String
    public var latency: TimeInterval
    public var usage: LLMUsage?

    public init(
        provider: ProviderKind,
        model: String,
        latency: TimeInterval,
        usage: LLMUsage? = nil
    ) {
        self.provider = provider
        self.model = model
        self.latency = latency
        self.usage = usage
    }

    public init(result: CleanupResult) {
        self.init(
            provider: result.provider,
            model: result.model,
            latency: result.latency,
            usage: .init(
                inputTokens: result.inputTokens,
                outputTokens: result.outputTokens
            )
        )
    }

    private enum CodingKeys: String, CodingKey {
        case provider, model, latency, usage
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        provider = try values.decode(ProviderKind.self, forKey: .provider)
        model = try values.decode(String.self, forKey: .model)
        latency = try values.decode(TimeInterval.self, forKey: .latency)
        usage = try values.decodeIfPresent(LLMUsage.self, forKey: .usage)
    }
}

public struct TranscriptRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public var rawText: String
    public var finalText: String
    public var sttProvider: ProviderKind
    public var sttModel: String
    public var sttLocale: String?
    public var sourceBundleID: String?
    public var audioDuration: TimeInterval
    public var sttLatency: TimeInterval
    public var pipelineLatency: TimeInterval?
    public var llmExecution: LLMExecution?
    public var insertionOutcome: String

    public init(
        id: UUID = UUID(), createdAt: Date = Date(), rawText: String, finalText: String,
        sttProvider: ProviderKind, sttModel: String, sttLocale: String? = nil, sourceBundleID: String? = nil, audioDuration: TimeInterval,
        sttLatency: TimeInterval, pipelineLatency: TimeInterval? = nil, llmExecution: LLMExecution? = nil,
        insertionOutcome: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.rawText = rawText
        self.finalText = finalText
        self.sttProvider = sttProvider
        self.sttModel = sttModel
        self.sttLocale = sttLocale
        self.sourceBundleID = sourceBundleID
        self.audioDuration = audioDuration
        self.sttLatency = sttLatency
        self.pipelineLatency = pipelineLatency
        self.llmExecution = llmExecution
        self.insertionOutcome = insertionOutcome
    }
}

public enum ProviderError: LocalizedError, Equatable, Sendable {
    case missingCredential(String)
    case invalidConfiguration(String)
    case invalidResponse
    case httpStatus(Int, String)
    case emptyTranscript
    case unsupported(String)
    case cleanupRejected(String)
    case transport(URLError.Code)

    public var errorDescription: String? {
        switch self {
        case .missingCredential(let field): "Missing \(field)."
        case .invalidConfiguration(let message): message
        case .invalidResponse: "The provider returned an invalid response."
        case .httpStatus(let status, let message): "Provider error \(status): \(message)"
        case .emptyTranscript: "The provider returned an empty transcript."
        case .unsupported(let message): message
        case .cleanupRejected(let reason): "Cleanup output was rejected: \(reason)"
        case .transport(let code): URLError(code).localizedDescription
        }
    }
}

public enum TransportFailureClassifier {
    private static let offlineEligibleCodes: Set<URLError.Code> = [
        .notConnectedToInternet,
        .networkConnectionLost,
        .cannotFindHost,
        .cannotConnectToHost,
        .dnsLookupFailed,
        .timedOut,
    ]

    public static func code(for error: any Error) -> URLError.Code? {
        if case ProviderError.transport(let code) = error { return code }
        return (error as? URLError)?.code
    }

    public static func isOfflineEligible(_ error: any Error) -> Bool {
        code(for: error).map(offlineEligibleCodes.contains) ?? false
    }
}
