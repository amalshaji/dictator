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

    public init(
        input: CleanupInput,
        vocabulary: [VocabularyEntry] = [],
        styleInstruction: String? = nil
    ) {
        self.input = input
        self.vocabulary = vocabulary
        self.styleInstruction = styleInstruction
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
    public var providerReportedCostUSD: Decimal?
    public var latency: TimeInterval

    public init(
        output: CleanupOutput,
        provider: ProviderKind,
        model: String,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        providerReportedCostUSD: Decimal? = nil,
        latency: TimeInterval
    ) {
        self.output = output
        self.provider = provider
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.providerReportedCostUSD = providerReportedCostUSD
        self.latency = latency
    }

    public var text: String { output.text }
    public var intent: CleanupIntent { output.intent }
}

public struct STTUsage: Codable, Equatable, Sendable {
    public var audioSeconds: TimeInterval
    public var providerBillableUnits: Decimal?
    public init(audioSeconds: TimeInterval, providerBillableUnits: Decimal? = nil) {
        self.audioSeconds = audioSeconds; self.providerBillableUnits = providerBillableUnits
    }
}

public struct LLMUsage: Codable, Equatable, Sendable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var providerReportedCostUSD: Decimal?
    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, providerReportedCostUSD: Decimal? = nil) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.providerReportedCostUSD = providerReportedCostUSD
    }
}

public enum TranscriptRevisionOrigin: String, Codable, Equatable, Sendable { case manual, localProcessing, cleanup }

public struct TranscriptRevision: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public var text: String
    public var origin: TranscriptRevisionOrigin
    public var llmProvider: ProviderKind?
    public var llmModel: String?
    public var repairLatency: TimeInterval
    public var llmUsage: LLMUsage?

    public init(id: UUID = UUID(), createdAt: Date = Date(), text: String, origin: TranscriptRevisionOrigin, llmProvider: ProviderKind? = nil, llmModel: String? = nil, repairLatency: TimeInterval, llmUsage: LLMUsage? = nil) {
        self.id = id; self.createdAt = createdAt; self.text = text; self.origin = origin
        self.llmProvider = llmProvider; self.llmModel = llmModel; self.repairLatency = repairLatency; self.llmUsage = llmUsage
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
    public var pipelineLatency: TimeInterval?
    public var sttUsage: STTUsage
    public var llmUsage: LLMUsage?
    public var insertionOutcome: String
    public var revisions: [TranscriptRevision]
    public var preferredRevisionID: UUID?

    public var currentText: String {
        guard let preferredRevisionID, let revision = revisions.first(where: { $0.id == preferredRevisionID }) else { return finalText }
        return revision.text
    }

    public init(
        id: UUID = UUID(), createdAt: Date = Date(), rawText: String, finalText: String,
        sttProvider: ProviderKind, sttModel: String, llmProvider: ProviderKind? = nil,
        llmModel: String? = nil, sourceBundleID: String? = nil, audioDuration: TimeInterval,
        sttLatency: TimeInterval, cleanupLatency: TimeInterval? = nil, pipelineLatency: TimeInterval? = nil,
        sttUsage: STTUsage? = nil, llmUsage: LLMUsage? = nil, insertionOutcome: String,
        revisions: [TranscriptRevision] = [], preferredRevisionID: UUID? = nil
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
        self.pipelineLatency = pipelineLatency
        self.sttUsage = sttUsage ?? STTUsage(audioSeconds: audioDuration)
        self.llmUsage = llmUsage
        self.insertionOutcome = insertionOutcome
        self.revisions = revisions
        self.preferredRevisionID = preferredRevisionID
    }

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, rawText, finalText, sttProvider, sttModel, llmProvider, llmModel, sourceBundleID
        case audioDuration, sttLatency, cleanupLatency, pipelineLatency, sttUsage, llmUsage, insertionOutcome, revisions, preferredRevisionID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); createdAt = try c.decode(Date.self, forKey: .createdAt)
        rawText = try c.decode(String.self, forKey: .rawText); finalText = try c.decode(String.self, forKey: .finalText)
        sttProvider = try c.decode(ProviderKind.self, forKey: .sttProvider); sttModel = try c.decode(String.self, forKey: .sttModel)
        llmProvider = try c.decodeIfPresent(ProviderKind.self, forKey: .llmProvider); llmModel = try c.decodeIfPresent(String.self, forKey: .llmModel)
        sourceBundleID = try c.decodeIfPresent(String.self, forKey: .sourceBundleID)
        audioDuration = try c.decode(TimeInterval.self, forKey: .audioDuration); sttLatency = try c.decode(TimeInterval.self, forKey: .sttLatency)
        cleanupLatency = try c.decodeIfPresent(TimeInterval.self, forKey: .cleanupLatency); pipelineLatency = try c.decodeIfPresent(TimeInterval.self, forKey: .pipelineLatency)
        sttUsage = try c.decodeIfPresent(STTUsage.self, forKey: .sttUsage) ?? .init(audioSeconds: audioDuration)
        llmUsage = try c.decodeIfPresent(LLMUsage.self, forKey: .llmUsage); insertionOutcome = try c.decode(String.self, forKey: .insertionOutcome)
        revisions = try c.decodeIfPresent([TranscriptRevision].self, forKey: .revisions) ?? []
        preferredRevisionID = try c.decodeIfPresent(UUID.self, forKey: .preferredRevisionID)
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
