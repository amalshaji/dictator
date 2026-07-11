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

public struct CleanupExecution: Codable, Equatable, Sendable {
    public var provider: ProviderKind
    public var model: String
    public var latency: TimeInterval
    public var usage: LLMUsage?

    public init(provider: ProviderKind, model: String, latency: TimeInterval, usage: LLMUsage? = nil) {
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
                outputTokens: result.outputTokens,
                providerReportedCostUSD: result.providerReportedCostUSD
            )
        )
    }
}

public enum TranscriptRevisionOrigin: Equatable, Sendable {
    case manual
    case localProcessing
    case cleanup(CleanupExecution)

    public var label: String {
        switch self {
        case .manual: "manual"
        case .localProcessing: "localProcessing"
        case .cleanup: "cleanup"
        }
    }
}

public struct TranscriptRevision: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public var text: String
    public var origin: TranscriptRevisionOrigin
    public var repairLatency: TimeInterval

    public init(id: UUID = UUID(), createdAt: Date = Date(), text: String, origin: TranscriptRevisionOrigin, repairLatency: TimeInterval) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
        self.origin = origin
        self.repairLatency = repairLatency
    }

    private enum OriginKind: String, Codable { case manual, localProcessing, cleanup }
    private enum CodingKeys: String, CodingKey {
        case id, createdAt, text, origin, cleanup, repairLatency
        case llmProvider, llmModel, llmUsage
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        text = try values.decode(String.self, forKey: .text)
        repairLatency = try values.decode(TimeInterval.self, forKey: .repairLatency)
        switch try values.decode(OriginKind.self, forKey: .origin) {
        case .manual:
            origin = .manual
        case .localProcessing:
            origin = .localProcessing
        case .cleanup:
            if let execution = try values.decodeIfPresent(CleanupExecution.self, forKey: .cleanup) {
                origin = .cleanup(execution)
            } else {
                let provider = try values.decode(ProviderKind.self, forKey: .llmProvider)
                let model = try values.decode(String.self, forKey: .llmModel)
                let usage = try values.decodeIfPresent(LLMUsage.self, forKey: .llmUsage)
                origin = .cleanup(.init(provider: provider, model: model, latency: repairLatency, usage: usage))
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(text, forKey: .text)
        try values.encode(repairLatency, forKey: .repairLatency)
        switch origin {
        case .manual:
            try values.encode(OriginKind.manual, forKey: .origin)
        case .localProcessing:
            try values.encode(OriginKind.localProcessing, forKey: .origin)
        case .cleanup(let execution):
            try values.encode(OriginKind.cleanup, forKey: .origin)
            try values.encode(execution, forKey: .cleanup)
        }
    }
}

public struct TranscriptRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public var rawText: String
    public var finalText: String
    public var sttProvider: ProviderKind
    public var sttModel: String
    public var sourceBundleID: String?
    public var audioDuration: TimeInterval
    public var sttLatency: TimeInterval
    public var pipelineLatency: TimeInterval?
    public var cleanup: CleanupExecution?
    public var insertionOutcome: String
    public var revisions: [TranscriptRevision]
    public var preferredRevisionID: UUID?

    public var currentText: String {
        guard let preferredRevisionID, let revision = revisions.first(where: { $0.id == preferredRevisionID }) else { return finalText }
        return revision.text
    }

    public var sttUsage: STTUsage { STTUsage(audioSeconds: audioDuration) }

    public init(
        id: UUID = UUID(), createdAt: Date = Date(), rawText: String, finalText: String,
        sttProvider: ProviderKind, sttModel: String, sourceBundleID: String? = nil, audioDuration: TimeInterval,
        sttLatency: TimeInterval, pipelineLatency: TimeInterval? = nil, cleanup: CleanupExecution? = nil, insertionOutcome: String,
        revisions: [TranscriptRevision] = [], preferredRevisionID: UUID? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.rawText = rawText
        self.finalText = finalText
        self.sttProvider = sttProvider
        self.sttModel = sttModel
        self.sourceBundleID = sourceBundleID
        self.audioDuration = audioDuration
        self.sttLatency = sttLatency
        self.pipelineLatency = pipelineLatency
        self.cleanup = cleanup
        self.insertionOutcome = insertionOutcome
        self.revisions = revisions
        self.preferredRevisionID = preferredRevisionID
    }

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, rawText, finalText, sttProvider, sttModel, sourceBundleID
        case audioDuration, sttLatency, pipelineLatency, cleanup, insertionOutcome, revisions, preferredRevisionID
        case llmProvider, llmModel, cleanupLatency, llmUsage
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); createdAt = try c.decode(Date.self, forKey: .createdAt)
        rawText = try c.decode(String.self, forKey: .rawText); finalText = try c.decode(String.self, forKey: .finalText)
        sttProvider = try c.decode(ProviderKind.self, forKey: .sttProvider); sttModel = try c.decode(String.self, forKey: .sttModel)
        sourceBundleID = try c.decodeIfPresent(String.self, forKey: .sourceBundleID)
        audioDuration = try c.decode(TimeInterval.self, forKey: .audioDuration); sttLatency = try c.decode(TimeInterval.self, forKey: .sttLatency)
        pipelineLatency = try c.decodeIfPresent(TimeInterval.self, forKey: .pipelineLatency)
        if let execution = try c.decodeIfPresent(CleanupExecution.self, forKey: .cleanup) {
            cleanup = execution
        } else if let provider = try c.decodeIfPresent(ProviderKind.self, forKey: .llmProvider),
                  let model = try c.decodeIfPresent(String.self, forKey: .llmModel) {
            cleanup = .init(
                provider: provider,
                model: model,
                latency: try c.decodeIfPresent(TimeInterval.self, forKey: .cleanupLatency) ?? 0,
                usage: try c.decodeIfPresent(LLMUsage.self, forKey: .llmUsage)
            )
        } else {
            cleanup = nil
        }
        insertionOutcome = try c.decode(String.self, forKey: .insertionOutcome)
        revisions = try c.decodeIfPresent([TranscriptRevision].self, forKey: .revisions) ?? []
        preferredRevisionID = try c.decodeIfPresent(UUID.self, forKey: .preferredRevisionID)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(createdAt, forKey: .createdAt)
        try c.encode(rawText, forKey: .rawText); try c.encode(finalText, forKey: .finalText)
        try c.encode(sttProvider, forKey: .sttProvider); try c.encode(sttModel, forKey: .sttModel)
        try c.encodeIfPresent(sourceBundleID, forKey: .sourceBundleID)
        try c.encode(audioDuration, forKey: .audioDuration); try c.encode(sttLatency, forKey: .sttLatency)
        try c.encodeIfPresent(pipelineLatency, forKey: .pipelineLatency)
        try c.encodeIfPresent(cleanup, forKey: .cleanup)
        try c.encode(insertionOutcome, forKey: .insertionOutcome)
        try c.encode(revisions, forKey: .revisions)
        try c.encodeIfPresent(preferredRevisionID, forKey: .preferredRevisionID)
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
