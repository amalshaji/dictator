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
    public static let sttPricingSource = URL(string: "https://console.groq.com/docs/speech-to-text")!
    public static let fallbackRates: [String: ModelTokenRate] = [
        "groq/openai/gpt-oss-20b": .init(inputPerMillion: 0.10, outputPerMillion: 0.50),
        "google/gemini-2.5-flash-lite": .init(inputPerMillion: 0.10, outputPerMillion: 0.40),
        "xai/grok-4.20-0309-non-reasoning": .init(inputPerMillion: 2, outputPerMillion: 10),
        "cloudflare-workers-ai/@cf/qwen/qwen3-30b-a3b-fp8": .init(inputPerMillion: 0.051, outputPerMillion: 0.335)
    ]

    public static func estimatedSTTCost(provider: ProviderKind, model: String, audioSeconds: TimeInterval) -> Decimal? {
        let hourlyRate: Decimal
        switch provider {
        case .groq: hourlyRate = model == "whisper-large-v3" ? 0.111 : 0.04
        case .cloudflare: hourlyRate = 0.03
        case .xAI: hourlyRate = 0.10
        case .deepgram: hourlyRate = 0.29
        case .assemblyAI: hourlyRate = 0.15
        case .gladia: hourlyRate = 0.61
        default: return nil
        }
        let billableSeconds = provider == .groq ? max(audioSeconds, 10) : audioSeconds
        return hourlyRate * Decimal(billableSeconds / 3_600)
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
        guard let providerID = providerID(for: provider), let rate = rates["\(providerID)/\(model)"] else { return nil }
        return Decimal(usage.inputTokens) * rate.inputPerMillion / 1_000_000
            + Decimal(usage.outputTokens) * rate.outputPerMillion / 1_000_000
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
            if let usage = record.llmUsage, let provider = record.llmProvider, let model = record.llmModel {
                result.cleanupRequests += 1; result.inputTokens += usage.inputTokens; result.outputTokens += usage.outputTokens
                if let cost = PricingCatalog.estimatedLLMCost(provider: provider, model: model, usage: usage, rates: rates) { result.llmCost += cost; result.pricedLLMCount += 1 }
            }
            for revision in record.revisions where revision.origin == .cleanup {
                guard let usage = revision.llmUsage, let provider = revision.llmProvider, let model = revision.llmModel else { continue }
                result.cleanupRequests += 1; result.inputTokens += usage.inputTokens; result.outputTokens += usage.outputTokens
                if let cost = PricingCatalog.estimatedLLMCost(provider: provider, model: model, usage: usage, rates: rates) { result.llmCost += cost; result.pricedLLMCount += 1 }
            }
        }
        result.cleanupMedianLatency = median(records.compactMap(\.cleanupLatency) + records.flatMap(\.revisions).filter { $0.origin == .cleanup }.map(\.repairLatency))
        return result
    }

    private static func median(_ values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }; let sorted = values.sorted(); let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
