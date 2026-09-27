import Foundation

public enum ProviderRegistry {
    public static let appleSpeechMetadata = ProviderMetadata(
        kind: .appleSpeech,
        displayName: "Apple On-Device",
        defaultModel: AppleTranscriptionEngine.speechTranscriber.rawValue,
        models: [AppleTranscriptionEngine.speechTranscriber.rawValue, AppleTranscriptionEngine.dictationTranscriber.rawValue]
    )

    public static func sttProvider(for kind: ProviderKind) -> (any SpeechToTextProvider)? {
        switch kind {
        case .groq: GroqSTTProvider()
        case .deepgram: DeepgramSTTProvider()
        default: nil
        }
    }

    public static let sttMetadata: [ProviderMetadata] = [GroqSTTProvider().metadata, DeepgramSTTProvider().metadata]

    public static func sttMetadata(includeAppleSpeech: Bool) -> [ProviderMetadata] {
        includeAppleSpeech ? [appleSpeechMetadata] + sttMetadata : sttMetadata
    }
}

public enum STTProviderSelection {
    public static func resolve(
        savedRawValue: String?,
        appleSpeechAvailable: Bool,
        lastCloudRawValue: String? = nil,
        existingInstallation: Bool = false
    ) -> ProviderKind {
        guard let savedRawValue, let saved = ProviderKind(rawValue: savedRawValue) else {
            if existingInstallation { return .groq }
            return appleSpeechAvailable ? .appleSpeech : .groq
        }
        guard saved == .appleSpeech, !appleSpeechAvailable else { return saved }
        return lastCloudRawValue.flatMap(ProviderKind.init(rawValue:)).flatMap { $0 == .appleSpeech ? nil : $0 } ?? .groq
    }

    public static func prepareTransition(
        from current: ProviderKind,
        to next: ProviderKind,
        selectedCleanup: ProviderKind,
        store: any CredentialStoring
    ) throws -> ProviderKind? {
        if next == .appleSpeech {
            try CredentialReuseMigration.preserveCleanupCredential(
                previousSTT: current,
                selectedCleanup: selectedCleanup,
                store: store
            )
            return current == .appleSpeech ? nil : current
        }
        return next
    }
}
