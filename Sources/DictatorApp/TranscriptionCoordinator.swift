import DictatorCore
import Foundation

struct TranscriptionRun: Equatable {
    let result: TranscriptionResult
    let usedAppleFallback: Bool

    var allowsCleanup: Bool { !usedAppleFallback }
}

@MainActor
protocol TranscriptionCoordinating: AnyObject, Sendable {
    func transcribe(
        audio: RecordedAudio,
        selectedProvider: ProviderKind,
        selectedModel: String?,
        vocabulary: [VocabularyEntry]
    ) async throws -> TranscriptionRun

    /// Opens the selected cloud provider's HTTPS connection ahead of the
    /// transcribe request so the DNS/TCP/TLS handshake overlaps recording
    /// instead of adding to post-dictation latency. A no-op for Apple
    /// On-Device transcription, which makes no network request.
    func warmUp(selectedProvider: ProviderKind) async
}

extension TranscriptionCoordinating {
    func warmUp(selectedProvider: ProviderKind) async {}
}

@MainActor
final class TranscriptionCoordinator: TranscriptionCoordinating {
    private let keychain: any CredentialStoring
    private let appleSpeech: AppleSpeechCoordinator
    private let provider: (ProviderKind) -> (any SpeechToTextProvider)?

    init(
        keychain: any CredentialStoring,
        appleSpeech: AppleSpeechCoordinator,
        provider: @escaping (ProviderKind) -> (any SpeechToTextProvider)? = ProviderRegistry.sttProvider
    ) {
        self.keychain = keychain
        self.appleSpeech = appleSpeech
        self.provider = provider
    }

    func transcribe(
        audio: RecordedAudio,
        selectedProvider: ProviderKind,
        selectedModel: String?,
        vocabulary: [VocabularyEntry]
    ) async throws -> TranscriptionRun {
        if selectedProvider == .appleSpeech {
            if !appleSpeech.state.readiness.isReady { await appleSpeech.refresh() }
            do {
                let result = try await appleSpeech.transcribe(audio: audio, vocabulary: vocabulary)
                return .init(result: result, usedAppleFallback: false)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                await appleSpeech.refresh()
                throw error
            }
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
                return .init(result: result, usedAppleFallback: false)
            } catch {
                if TransportFailureClassifier.isOfflineEligible(error) {
                    if !appleSpeech.state.readiness.isReady { await appleSpeech.refresh() }
                    if appleSpeech.state.readiness.isReady {
                        let fallbackResult = try await appleSpeech.transcribe(audio: audio, vocabulary: vocabulary)
                        return .init(result: fallbackResult, usedAppleFallback: true)
                    }
                }
                guard attempt < 2, isRetryable(error) else { throw error }
                try? await Task.sleep(for: .milliseconds(250 * (attempt + 1)))
            }
        }
        throw ProviderError.invalidResponse
    }

    private func isRetryable(_ error: any Error) -> Bool {
        if case ProviderError.httpStatus(let status, _) = error {
            return [408, 429, 502, 503].contains(status)
        }
        // A 20 s request timeout should surface immediately rather than
        // tripling the wait, so `.timedOut` is excluded from the retryable codes.
        guard let code = TransportFailureClassifier.code(for: error) else { return false }
        return code != .timedOut
    }

    func warmUp(selectedProvider: ProviderKind) async {
        guard selectedProvider != .appleSpeech,
              let provider = provider(selectedProvider),
              let credentials = try? keychain.load(for: .speechToText, provider: selectedProvider)
        else { return }
        await provider.warmUpConnection(credentials: credentials)
    }
}
