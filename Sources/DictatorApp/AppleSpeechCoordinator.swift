import DictatorCore
import Foundation

struct AppleSpeechSetupState: Equatable {
    var selectedLocaleIdentifier: String
    var locales: [AppleSpeechLocale]
    var readiness: AppleSpeechReadiness

    var readyLocale: AppleSpeechLocale? {
        guard case .ready(let locale) = readiness,
              locale.identifier == selectedLocaleIdentifier
        else { return nil }
        return locale
    }
}

@MainActor
final class AppleSpeechCoordinator: ObservableObject {
    @Published private(set) var state: AppleSpeechSetupState

    let isAvailable: Bool
    private let provider: (any LocalSpeechTranscribing)?
    private let persistSelection: (String) -> Void
    private var generation = 0

    init(
        provider: (any LocalSpeechTranscribing)?,
        selectedLocaleIdentifier: String,
        persistSelection: @escaping (String) -> Void
    ) {
        self.provider = provider
        self.persistSelection = persistSelection
        isAvailable = provider != nil
        state = .init(
            selectedLocaleIdentifier: selectedLocaleIdentifier,
            locales: [],
            readiness: .checking
        )
    }

    var statusText: String {
        switch state.readiness {
        case .checking: "Checking model availability…"
        case .downloadRequired(let locale): "Download \(displayName(for: locale.identifier)) to use Apple On-Device."
        case .downloading(_, let progress): "Downloading model… \(Int(progress * 100))%"
        case .ready(let locale): "Ready · \(displayName(for: locale.identifier)) · \(engineName(locale.engine))"
        case .unavailable(let reason), .failed(let reason): reason
        }
    }

    func selectLocale(_ identifier: String) {
        guard state.locales.contains(where: { $0.identifier == identifier }) else { return }
        generation += 1
        state.selectedLocaleIdentifier = identifier
        state.readiness = .checking
        persistSelection(identifier)
        let expectedGeneration = generation
        Task { await refresh(expectedGeneration: expectedGeneration) }
    }

    func refresh() async {
        generation += 1
        await refresh(expectedGeneration: generation)
    }

    func prepare() async {
        guard let provider else {
            state.readiness = .unavailable("Apple On-Device transcription requires macOS 26 or later.")
            return
        }
        if state.locales.isEmpty { await refresh() }
        if state.readiness.isReady { return }
        guard let locale = state.readiness.locale
                ?? state.locales.first(where: { $0.identifier == state.selectedLocaleIdentifier })
        else { return }

        generation += 1
        let expectedGeneration = generation
        let expectedIdentifier = state.selectedLocaleIdentifier
        state.readiness = .downloading(locale, progress: 0)
        do {
            let readiness = try await provider.installAssets(for: expectedIdentifier) { [weak self] progress in
                Task { @MainActor in
                    guard let self,
                          self.generation == expectedGeneration,
                          self.state.selectedLocaleIdentifier == expectedIdentifier
                    else { return }
                    self.state.readiness = .downloading(locale, progress: min(max(progress, 0), 1))
                }
            }
            guard generation == expectedGeneration,
                  state.selectedLocaleIdentifier == expectedIdentifier
            else { return }
            apply(readiness, for: expectedIdentifier)
        } catch is CancellationError {
            guard generation == expectedGeneration,
                  state.selectedLocaleIdentifier == expectedIdentifier
            else { return }
            state.readiness = .checking
            Task { await self.refresh() }
            return
        } catch {
            guard generation == expectedGeneration,
                  state.selectedLocaleIdentifier == expectedIdentifier
            else { return }
            state.readiness = .failed("Model download failed: \(error.localizedDescription)")
        }
    }

    func transcribe(audio: RecordedAudio, vocabulary: [VocabularyEntry]) async throws -> TranscriptionResult {
        guard let provider else {
            throw ProviderError.unsupported("Apple On-Device transcription requires macOS 26 or later.")
        }
        guard let locale = state.readyLocale else {
            throw ProviderError.invalidConfiguration("Download the selected Apple speech model before dictating.")
        }
        return try await provider.transcribe(
            audio: audio,
            localeIdentifier: locale.identifier,
            vocabulary: vocabulary
        )
    }

    private func refresh(expectedGeneration: Int) async {
        guard let provider else {
            guard generation == expectedGeneration else { return }
            state = .init(
                selectedLocaleIdentifier: state.selectedLocaleIdentifier,
                locales: [],
                readiness: .unavailable("Apple On-Device transcription requires macOS 26 or later.")
            )
            return
        }

        let requestedIdentifier = state.selectedLocaleIdentifier
        let locales = await provider.availableLocales()
        guard generation == expectedGeneration else { return }
        guard !locales.isEmpty else {
            state = .init(
                selectedLocaleIdentifier: requestedIdentifier,
                locales: [],
                readiness: .unavailable("No Apple speech languages are available on this Mac.")
            )
            return
        }

        let selectedIdentifier = resolvedSelection(requestedIdentifier, from: locales)
        state = .init(
            selectedLocaleIdentifier: selectedIdentifier,
            locales: locales,
            readiness: .checking
        )
        if selectedIdentifier != requestedIdentifier { persistSelection(selectedIdentifier) }

        let readiness = await provider.readiness(for: selectedIdentifier)
        guard generation == expectedGeneration,
              state.selectedLocaleIdentifier == selectedIdentifier
        else { return }
        apply(readiness, for: selectedIdentifier)
    }

    private func apply(_ readiness: AppleSpeechReadiness, for requestedIdentifier: String) {
        let resolvedIdentifier = readiness.locale?.identifier ?? requestedIdentifier
        if state.locales.contains(where: { $0.identifier == resolvedIdentifier }),
           resolvedIdentifier != state.selectedLocaleIdentifier {
            state.selectedLocaleIdentifier = resolvedIdentifier
            persistSelection(resolvedIdentifier)
        }
        state.readiness = readiness
    }

    private func resolvedSelection(_ requestedIdentifier: String, from locales: [AppleSpeechLocale]) -> String {
        if locales.contains(where: { $0.identifier == requestedIdentifier }) { return requestedIdentifier }
        let requestedLanguage = Locale(identifier: requestedIdentifier).language.languageCode
        return locales.first {
            Locale(identifier: $0.identifier).language.languageCode == requestedLanguage
        }?.identifier ?? locales[0].identifier
    }

    private func displayName(for localeIdentifier: String) -> String {
        Locale.current.localizedString(forIdentifier: localeIdentifier) ?? localeIdentifier
    }

    private func engineName(_ engine: AppleTranscriptionEngine) -> String {
        switch engine {
        case .speechTranscriber: "SpeechTranscriber"
        case .dictationTranscriber: "Dictation fallback"
        }
    }
}
