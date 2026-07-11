import Foundation

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
        if provider == .appleSpeech { return 0 }
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
