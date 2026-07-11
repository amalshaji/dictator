import Foundation

public struct ModelTokenRate: Codable, Equatable, Sendable {
    public let inputPerMillion: Decimal
    public let outputPerMillion: Decimal
}

public struct PricingSnapshot: Codable, Equatable, Sendable {
    public var fetchedAt: Date
    public var rates: [String: ModelTokenRate]
    public init(fetchedAt: Date, rates: [String: ModelTokenRate]) { self.fetchedAt = fetchedAt; self.rates = rates }
}

public struct PricingCatalog: Sendable {
    public static let checkedAt = "2026-07-10"
    public struct STTRate: Equatable, Sendable {
        public let provider: ProviderKind
        public let model: String
        public let hourlyUSD: Decimal
        public let minimumBillableSeconds: TimeInterval?
        public let checkedAt: String
        public let sourceURL: URL
    }
    public static let sttRates: [STTRate] = [
        .init(provider: .groq, model: "whisper-large-v3-turbo", hourlyUSD: 0.04, minimumBillableSeconds: 10, checkedAt: checkedAt, sourceURL: URL(string: "https://console.groq.com/docs/speech-to-text")!),
        .init(provider: .groq, model: "whisper-large-v3", hourlyUSD: 0.111, minimumBillableSeconds: 10, checkedAt: checkedAt, sourceURL: URL(string: "https://console.groq.com/docs/speech-to-text")!),
        .init(provider: .cloudflare, model: "@cf/openai/whisper-large-v3-turbo", hourlyUSD: 0.03, minimumBillableSeconds: nil, checkedAt: checkedAt, sourceURL: URL(string: "https://developers.cloudflare.com/workers-ai/platform/pricing/")!),
        .init(provider: .cloudflare, model: "@cf/openai/whisper", hourlyUSD: 0.03, minimumBillableSeconds: nil, checkedAt: checkedAt, sourceURL: URL(string: "https://developers.cloudflare.com/workers-ai/platform/pricing/")!),
        .init(provider: .xAI, model: "grok-transcribe", hourlyUSD: 0.10, minimumBillableSeconds: nil, checkedAt: checkedAt, sourceURL: URL(string: "https://docs.x.ai/docs/models")!),
        .init(provider: .deepgram, model: "nova-3", hourlyUSD: 0.29, minimumBillableSeconds: nil, checkedAt: checkedAt, sourceURL: URL(string: "https://deepgram.com/pricing")!),
        .init(provider: .deepgram, model: "nova-3-general", hourlyUSD: 0.29, minimumBillableSeconds: nil, checkedAt: checkedAt, sourceURL: URL(string: "https://deepgram.com/pricing")!),
        .init(provider: .assemblyAI, model: "universal-3-pro", hourlyUSD: 0.15, minimumBillableSeconds: nil, checkedAt: checkedAt, sourceURL: URL(string: "https://www.assemblyai.com/pricing")!),
        .init(provider: .assemblyAI, model: "universal-2", hourlyUSD: 0.15, minimumBillableSeconds: nil, checkedAt: checkedAt, sourceURL: URL(string: "https://www.assemblyai.com/pricing")!),
        .init(provider: .gladia, model: "solaria-1", hourlyUSD: 0.61, minimumBillableSeconds: nil, checkedAt: checkedAt, sourceURL: URL(string: "https://www.gladia.io/pricing")!)
    ]
    public static let fallbackRates: [String: ModelTokenRate] = [
        "groq/openai/gpt-oss-20b": .init(inputPerMillion: 0.075, outputPerMillion: 0.30),
        "google/gemini-2.5-flash-lite": .init(inputPerMillion: 0.10, outputPerMillion: 0.40),
        "xai/grok-4.20-0309-non-reasoning": .init(inputPerMillion: 1.25, outputPerMillion: 2.5),
        "cloudflare-workers-ai/@cf/qwen/qwen3-30b-a3b-fp8": .init(inputPerMillion: 0.0509, outputPerMillion: 0.335)
    ]

    public static func estimatedSTTCost(provider: ProviderKind, model: String, audioSeconds: TimeInterval) -> Decimal? {
        guard let rate = sttRates.first(where: { $0.provider == provider && $0.model == model }) else { return nil }
        let billableSeconds = max(audioSeconds, rate.minimumBillableSeconds ?? 0)
        return rate.hourlyUSD * Decimal(billableSeconds / 3_600)
    }

    public static func providerID(for provider: ProviderKind) -> String? {
        switch provider {
        case .groq: "groq"
        case .xAI: "xai"
        case .gemini: "google"
        case .openRouter: "openrouter"
        case .cloudflare: "cloudflare-workers-ai"
        default: nil
        }
    }

    public static func estimatedLLMCost(provider: ProviderKind, model: String, usage: LLMUsage, rates: [String: ModelTokenRate]) -> Decimal? {
        if let reported = usage.providerReportedCostUSD { return reported }
        guard let inputTokens = usage.inputTokens, let outputTokens = usage.outputTokens,
              let providerID = providerID(for: provider), let rate = rates["\(providerID)/\(model)"] else { return nil }
        return Decimal(inputTokens) * rate.inputPerMillion / 1_000_000
            + Decimal(outputTokens) * rate.outputPerMillion / 1_000_000
    }
}

public actor PricingService {
    public static let endpoint = URL(string: "https://models.dev/api.json")!
    private let cacheURL: URL
    private let session: URLSession
    private let maxAge: TimeInterval = 24 * 60 * 60
    private var snapshot: PricingSnapshot?

    public init(cacheURL: URL = PricingService.applicationSupportCacheURL(), session: URLSession = .shared) {
        self.cacheURL = cacheURL; self.session = session
    }

    public static func applicationSupportCacheURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appending(path: "Dictator", directoryHint: .isDirectory).appending(path: "pricing.json")
    }

    public func current() -> PricingSnapshot? {
        if let snapshot { return snapshot }
        guard let data = try? Data(contentsOf: cacheURL), let cached = try? JSONDecoder().decode(PricingSnapshot.self, from: data) else { return nil }
        snapshot = cached; return cached
    }

    @discardableResult
    public func refreshIfNeeded(force: Bool = false, now: Date = Date()) async throws -> PricingSnapshot {
        if !force, let current = current(), now.timeIntervalSince(current.fetchedAt) < maxAge { return current }
        let (data, response) = try await session.data(from: Self.endpoint)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ProviderError.invalidResponse }
        let rates = try Self.decodeRates(from: data)
        let fresh = PricingSnapshot(fetchedAt: now, rates: Self.withFallbacks(rates))
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(fresh).write(to: cacheURL, options: .atomic)
        snapshot = fresh
        return fresh
    }

    public static func decodeRates(from data: Data) throws -> [String: ModelTokenRate] {
        let providers = try JSONDecoder().decode([String: ModelsDevProvider].self, from: data)
        var result: [String: ModelTokenRate] = [:]
        for (providerID, provider) in providers {
            for (modelID, model) in provider.models {
                guard let input = model.cost?.input, let output = model.cost?.output else { continue }
                result["\(providerID)/\(modelID)"] = .init(inputPerMillion: input, outputPerMillion: output)
            }
        }
        return result
    }

    private static func withFallbacks(_ rates: [String: ModelTokenRate]) -> [String: ModelTokenRate] {
        PricingCatalog.fallbackRates.merging(rates) { _, live in live }
    }

    private struct ModelsDevProvider: Decodable { let models: [String: Model] }
    private struct Model: Decodable { let cost: Cost?; struct Cost: Decodable { let input: Decimal?; let output: Decimal? } }
}

public struct UsageSummary: Equatable, Sendable {
    public var dictations = 0
    public var audioSeconds: TimeInterval = 0
    public var words = 0
    public var sttCost: Decimal = 0
    public var pricedSTTCount = 0
    public var sttMedianLatency: TimeInterval?
    public var cleanupRequests = 0
    public var inputTokens = 0
    public var outputTokens = 0
    public var inputTokenSamples = 0
    public var outputTokenSamples = 0
    public var llmCost: Decimal = 0
    public var pricedLLMCount = 0
    public var cleanupMedianLatency: TimeInterval?
}

public enum UsageAnalytics {
    public static func summarize(_ records: [TranscriptRecord], since cutoff: Date, rates: [String: ModelTokenRate]) -> UsageSummary {
        let records = records.filter { $0.createdAt >= cutoff }
        var result = UsageSummary()
        result.dictations = records.count
        result.audioSeconds = records.reduce(0) { $0 + $1.audioDuration }
        result.words = records.reduce(0) { $0 + $1.currentText.split(whereSeparator: \.isWhitespace).count }
        let sttLatencies = records.map(\.sttLatency)
        result.sttMedianLatency = median(sttLatencies)
        for record in records {
            if let cost = PricingCatalog.estimatedSTTCost(provider: record.sttProvider, model: record.sttModel, audioSeconds: record.audioDuration) { result.sttCost += cost; result.pricedSTTCount += 1 }
            if let provider = record.llmProvider, let model = record.llmModel {
                result.cleanupRequests += 1
                if let tokens = record.llmUsage?.inputTokens { result.inputTokens += tokens; result.inputTokenSamples += 1 }
                if let tokens = record.llmUsage?.outputTokens { result.outputTokens += tokens; result.outputTokenSamples += 1 }
                if let usage = record.llmUsage, let cost = PricingCatalog.estimatedLLMCost(provider: provider, model: model, usage: usage, rates: rates) { result.llmCost += cost; result.pricedLLMCount += 1 }
            }
            for revision in record.revisions where revision.origin == .cleanup {
                result.cleanupRequests += 1
                if let tokens = revision.llmUsage?.inputTokens { result.inputTokens += tokens; result.inputTokenSamples += 1 }
                if let tokens = revision.llmUsage?.outputTokens { result.outputTokens += tokens; result.outputTokenSamples += 1 }
                if let usage = revision.llmUsage, let provider = revision.llmProvider, let model = revision.llmModel,
                   let cost = PricingCatalog.estimatedLLMCost(provider: provider, model: model, usage: usage, rates: rates) { result.llmCost += cost; result.pricedLLMCount += 1 }
            }
        }
        result.cleanupMedianLatency = median(records.compactMap(\.cleanupLatency) + records.flatMap(\.revisions).filter { $0.origin == .cleanup }.map(\.repairLatency))
        return result
    }

    public static func median(_ values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }; let sorted = values.sorted(); let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
