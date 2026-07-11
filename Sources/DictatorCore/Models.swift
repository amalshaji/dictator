import Foundation

public enum ProviderKind: String, Codable, CaseIterable, Sendable {
    case groq
    case cloudflare
    case xAI = "xai"
    case deepgram
    case assemblyAI = "assemblyai"
    case gladia
    case gemini
    case openRouter = "openrouter"
    case openAICompatible = "openai-compatible"
}

public struct ProviderCredentials: Codable, Equatable, Sendable {
    public var apiKey: String
    public var accountID: String?
    public var baseURL: URL?

    public init(apiKey: String, accountID: String? = nil, baseURL: URL? = nil) {
        self.apiKey = apiKey
        self.accountID = accountID
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
    public var pronunciations: [String]
    public var language: String?
    public var isEnabled: Bool
    public var useCount: Int

    public init(
        id: UUID = UUID(),
        value: String,
        variants: [String] = [],
        pronunciations: [String] = [],
        language: String? = nil,
        isEnabled: Bool = true,
        useCount: Int = 0
    ) {
        self.id = id
        self.value = value
        self.variants = variants
        self.pronunciations = pronunciations
        self.language = language
        self.isEnabled = isEnabled
        self.useCount = useCount
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
    public var useCount: Int

    public init(id: UUID = UUID(), trigger: String, expansion: String, isEnabled: Bool = true, useCount: Int = 0) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
        self.isEnabled = isEnabled
        self.useCount = useCount
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
    public let requiresAccountID: Bool

    public var id: ProviderKind { kind }
}

public struct CleanupRequest: Equatable, Sendable {
    public var transcript: String
    public var selectedText: String?
    public var vocabulary: [VocabularyEntry]
    public var styleInstruction: String?

    public init(
        transcript: String,
        selectedText: String? = nil,
        vocabulary: [VocabularyEntry] = [],
        styleInstruction: String? = nil
    ) {
        self.transcript = transcript
        self.selectedText = selectedText
        self.vocabulary = vocabulary
        self.styleInstruction = styleInstruction
    }
}

public enum CleanupIntent: String, Codable, Equatable, Sendable {
    case transcription
    case transformation
}

public struct CleanupResult: Equatable, Sendable {
    public var text: String
    public var intent: CleanupIntent
    public var provider: ProviderKind
    public var model: String
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var latency: TimeInterval

    public init(
        text: String,
        intent: CleanupIntent = .transcription,
        provider: ProviderKind,
        model: String,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        latency: TimeInterval
    ) {
        self.text = text
        self.intent = intent
        self.provider = provider
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.latency = latency
    }
}

public struct TranscriptRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public var rawText: String
    public var finalText: String
    public var sttProvider: ProviderKind
    public var sttModel: String
    public var llmProvider: ProviderKind?
    public var llmModel: String?
    public var sourceBundleID: String?
    public var audioDuration: TimeInterval
    public var sttLatency: TimeInterval
    public var cleanupLatency: TimeInterval?
    public var insertionOutcome: String

    public init(
        id: UUID = UUID(), createdAt: Date = Date(), rawText: String, finalText: String,
        sttProvider: ProviderKind, sttModel: String, llmProvider: ProviderKind? = nil,
        llmModel: String? = nil, sourceBundleID: String? = nil, audioDuration: TimeInterval,
        sttLatency: TimeInterval, cleanupLatency: TimeInterval? = nil, insertionOutcome: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.rawText = rawText
        self.finalText = finalText
        self.sttProvider = sttProvider
        self.sttModel = sttModel
        self.llmProvider = llmProvider
        self.llmModel = llmModel
        self.sourceBundleID = sourceBundleID
        self.audioDuration = audioDuration
        self.sttLatency = sttLatency
        self.cleanupLatency = cleanupLatency
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

    public var errorDescription: String? {
        switch self {
        case .missingCredential(let field): "Missing \(field)."
        case .invalidConfiguration(let message): message
        case .invalidResponse: "The provider returned an invalid response."
        case .httpStatus(let status, let message): "Provider error \(status): \(message)"
        case .emptyTranscript: "The provider returned an empty transcript."
        case .unsupported(let message): message
        case .cleanupRejected(let reason): "Cleanup output was rejected: \(reason)"
        }
    }
}
