import Foundation

public enum ProviderRegistry {
    public static func sttProvider(for kind: ProviderKind) -> (any SpeechToTextProvider)? {
        switch kind {
        case .groq: GroqSTTProvider()
        case .cloudflare: CloudflareSTTProvider()
        case .xAI: XAISTTProvider()
        case .deepgram: DeepgramSTTProvider()
        case .assemblyAI: AssemblyAISTTProvider()
        case .gladia: GladiaSTTProvider()
        default: nil
        }
    }

    public static var sttMetadata: [ProviderMetadata] {
        [GroqSTTProvider().metadata, CloudflareSTTProvider().metadata, XAISTTProvider().metadata,
         DeepgramSTTProvider().metadata, AssemblyAISTTProvider().metadata, GladiaSTTProvider().metadata]
    }
}

func seconds(since instant: ContinuousClock.Instant) -> TimeInterval {
    let duration = instant.duration(to: .now)
    return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}
