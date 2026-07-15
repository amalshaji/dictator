import DictatorCore
import Foundation

enum TranscriptionMode: Equatable {
    case online
    case offline
}

struct TranscriptionRun: Equatable {
    let result: TranscriptionResult
    let mode: TranscriptionMode

    var allowsCleanup: Bool { mode == .online }
}

@MainActor
protocol TranscriptionCoordinating: AnyObject, Sendable {
    func transcribe(
        audio: RecordedAudio,
        selectedProvider: ProviderKind,
        selectedModel: String?,
        fallbackEnabled: Bool,
        vocabulary: [VocabularyEntry],
        onModeChange: (TranscriptionMode) -> Void
    ) async throws -> TranscriptionRun
}

extension TranscriptionCoordinating {
    func transcribe(
        audio: RecordedAudio,
        selectedProvider: ProviderKind,
        selectedModel: String?,
        fallbackEnabled: Bool,
        vocabulary: [VocabularyEntry]
    ) async throws -> TranscriptionRun {
        try await transcribe(
            audio: audio,
            selectedProvider: selectedProvider,
            selectedModel: selectedModel,
            fallbackEnabled: fallbackEnabled,
            vocabulary: vocabulary,
            onModeChange: { _ in }
        )
    }
}

@MainActor
final class TranscriptionCoordinator: TranscriptionCoordinating {
    private let keychain: any CredentialStoring
    private let appleSpeech: AppleSpeechCoordinator
    private let connectivity: any ConnectivityMonitoring
    private let provider: (ProviderKind) -> (any SpeechToTextProvider)?

    init(
        keychain: any CredentialStoring,
        appleSpeech: AppleSpeechCoordinator,
        connectivity: any ConnectivityMonitoring,
        provider: @escaping (ProviderKind) -> (any SpeechToTextProvider)? = ProviderRegistry.sttProvider
    ) {
        self.keychain = keychain
        self.appleSpeech = appleSpeech
        self.connectivity = connectivity
        self.provider = provider
    }

    func transcribe(
        audio: RecordedAudio,
        selectedProvider: ProviderKind,
        selectedModel: String?,
        fallbackEnabled: Bool,
        vocabulary: [VocabularyEntry],
        onModeChange: (TranscriptionMode) -> Void = { _ in }
    ) async throws -> TranscriptionRun {
        if selectedProvider == .appleSpeech {
            let mode = currentMode
            onModeChange(mode)
            let result = try await appleSpeech.transcribe(audio: audio, vocabulary: vocabulary)
            return .init(result: result, mode: mode)
        }

        if fallbackEnabled, connectivity.state == .offline {
            return try await transcribeWithApple(
                audio: audio,
                vocabulary: vocabulary,
                onModeChange: onModeChange
            )
        }

        guard let provider = provider(selectedProvider) else {
            throw ProviderError.unsupported("Provider is not available")
        }
        guard let credentials = try keychain.load(for: .speechToText, provider: selectedProvider) else {
            throw ProviderError.missingCredential("\(provider.metadata.displayName) API key")
        }
        let options = TranscriptionOptions(
            model: selectedModel ?? provider.metadata.defaultModel,
            vocabulary: vocabulary
        )

        for attempt in 0..<3 {
            do {
                let result = try await provider.transcribe(
                    audio: audio,
                    options: options,
                    credentials: credentials
                )
                let mode = currentMode
                onModeChange(mode)
                return .init(result: result, mode: mode)
            } catch {
                if fallbackEnabled, TransportFailureClassifier.isOfflineEligible(error) {
                    return try await transcribeWithApple(
                        audio: audio,
                        vocabulary: vocabulary,
                        onModeChange: onModeChange
                    )
                }
                guard attempt < 2, isRetryable(error) else { throw error }
                try? await Task.sleep(for: .milliseconds(250 * (attempt + 1)))
            }
        }
        throw ProviderError.invalidResponse
    }

    private var currentMode: TranscriptionMode {
        connectivity.state == .offline ? .offline : .online
    }

    private func transcribeWithApple(
        audio: RecordedAudio,
        vocabulary: [VocabularyEntry],
        onModeChange: (TranscriptionMode) -> Void
    ) async throws -> TranscriptionRun {
        onModeChange(.offline)
        if !appleSpeech.state.readiness.isReady { await appleSpeech.refresh() }
        guard appleSpeech.state.readiness.isReady else { throw offlineModelUnavailableError }
        do {
            let result = try await appleSpeech.transcribe(audio: audio, vocabulary: vocabulary)
            return .init(result: result, mode: .offline)
        } catch {
            await appleSpeech.refresh()
            guard appleSpeech.state.readiness.isReady else { throw offlineModelUnavailableError }
            throw error
        }
    }

    private var offlineModelUnavailableError: ProviderError {
        .invalidConfiguration("Offline model unavailable—connect and repair offline mode in Providers.")
    }

    private func isRetryable(_ error: any Error) -> Bool {
        if case ProviderError.httpStatus(let status, _) = error {
            return [408, 429, 502, 503].contains(status)
        }
        return TransportFailureClassifier.code(for: error) != nil
    }
}
