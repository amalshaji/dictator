import Foundation

public struct PricingCatalog: Sendable {
    public static let checkedAt = "2026-07-10"

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
        return hourlyRate * Decimal(audioSeconds / 3_600)
    }
}

