import DictatorCore
import Foundation
import XCTest
@testable import Dictator

@MainActor
final class OfflineDictationTests: XCTestCase {
    private let audio = RecordedAudio(wavData: Data(), duration: 1)

    func testCoordinatorUsesAppleWhenOfflineFallbackIsEnabled() async throws {
        let coordinator = try await makeCoordinator(
            connectivity: .offline,
            cloudProvider: StubSpeechProvider(result: .cloud)
        )

        let run = try await coordinator.transcribe(
            audio: audio,
            selectedProvider: .groq,
            selectedModel: "cloud-model",
            fallbackEnabled: true,
            vocabulary: []
        )

        XCTAssertEqual(run.result.provider, .appleSpeech)
        XCTAssertEqual(run.mode, .offline)
        XCTAssertFalse(run.allowsCleanup)
    }

    func testCoordinatorDoesNotUseAppleWithoutExplicitOptIn() async throws {
        let coordinator = try await makeCoordinator(
            connectivity: .offline,
            cloudProvider: StubSpeechProvider(result: .cloud)
        )

        let run = try await coordinator.transcribe(
            audio: audio,
            selectedProvider: .groq,
            selectedModel: "cloud-model",
            fallbackEnabled: false,
            vocabulary: []
        )

        XCTAssertEqual(run.result.provider, .groq)
        XCTAssertEqual(run.mode, .offline)
        XCTAssertFalse(run.allowsCleanup)
    }

    func testCoordinatorFallsBackAfterCloudTransportFailure() async throws {
        let coordinator = try await makeCoordinator(
            connectivity: .online,
            cloudProvider: StubSpeechProvider(error: ProviderError.transport(.networkConnectionLost))
        )

        let run = try await coordinator.transcribe(
            audio: audio,
            selectedProvider: .groq,
            selectedModel: "cloud-model",
            fallbackEnabled: true,
            vocabulary: []
        )

        XCTAssertEqual(run.result.provider, .appleSpeech)
        XCTAssertEqual(run.mode, .offline)
    }

    func testCoordinatorKeepsOnlineCloudRunEligibleForCleanup() async throws {
        let coordinator = try await makeCoordinator(
            connectivity: .online,
            cloudProvider: StubSpeechProvider(result: .cloud)
        )

        let run = try await coordinator.transcribe(
            audio: audio,
            selectedProvider: .groq,
            selectedModel: "cloud-model",
            fallbackEnabled: true,
            vocabulary: []
        )

        XCTAssertEqual(run.result.provider, .groq)
        XCTAssertEqual(run.mode, .online)
        XCTAssertTrue(run.allowsCleanup)
    }

    func testAppleOnboardingFailureDoesNotPartiallyEnableFallback() async throws {
        let suiteName = "ai.dictator.tests.offline.atomic.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "onboardingComplete")
        defaults.set(ProviderKind.groq.rawValue, forKey: "selectedSTT")

        let model = AppModel(
            keychain: FailingMigrationCredentialStore(),
            appleSpeechProvider: ReadyAppleSpeechProvider(),
            defaults: defaults,
            connectivity: StaticConnectivityMonitor(state: .online)
        )

        do {
            try await model.configureOnboardingProvider(kind: .appleSpeech, apiKey: "", accountID: nil)
            XCTFail("Apple selection should fail when cleanup credential preservation fails")
        } catch {}

        XCTAssertEqual(model.selectedSTT, .groq)
        XCTAssertFalse(model.offlineFallbackEnabled)
        XCTAssertFalse(defaults.bool(forKey: "offlineFallbackEnabled"))
    }

    func testOfflineFallbackSetupPersistsOnlyAfterExplicitConfiguration() async throws {
        let (model, defaults, suiteName) = try makeModel(provider: ReadyAppleSpeechProvider())
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(model.offlineFallbackEnabled)
        try await model.configureOfflineFallback()
        XCTAssertTrue(model.offlineFallbackEnabled)
        XCTAssertTrue(defaults.bool(forKey: "offlineFallbackEnabled"))

        model.disableOfflineFallback()
        XCTAssertFalse(model.offlineFallbackEnabled)
        XCTAssertFalse(defaults.bool(forKey: "offlineFallbackEnabled"))
    }

    func testFailedOfflineFallbackSetupRemainsDisabled() async throws {
        let (model, defaults, suiteName) = try makeModel(provider: UnavailableAppleSpeechProvider())
        defer { defaults.removePersistentDomain(forName: suiteName) }

        do {
            try await model.configureOfflineFallback()
            XCTFail("Unavailable Apple speech must not enable fallback")
        } catch {}

        XCTAssertFalse(model.offlineFallbackEnabled)
        XCTAssertFalse(defaults.bool(forKey: "offlineFallbackEnabled"))
    }

    func testChangingOfflineLanguageRequiresSetupAgain() async throws {
        let (model, defaults, suiteName) = try makeModel(
            provider: ReadyAppleSpeechProvider(),
            fallbackEnabled: true
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        await model.appleSpeech.refresh()

        model.selectAppleSpeechLocale("fr_FR")

        XCTAssertFalse(model.offlineFallbackEnabled)
        XCTAssertFalse(defaults.bool(forKey: "offlineFallbackEnabled"))
    }

    func testOnboardingIncludesOptionalOfflineModeBeforeScratchpad() {
        XCTAssertEqual(OnboardingStep.allCases, [.welcome, .permissions, .provider, .offlineMode, .ready])
        XCTAssertEqual(OnboardingStep.provider.next, .offlineMode)
        XCTAssertEqual(OnboardingStep.offlineMode.next, .ready)
    }

    func testOfflineHUDStateIsExplicitThroughCompletion() {
        XCTAssertEqual(HUDPhase.offline.label, "Offline mode")
        XCTAssertEqual(HUDPhase.success("Offline · Paste sent").label, "Offline · Paste sent")
    }

    private func makeCoordinator(
        connectivity: ConnectivityState,
        cloudProvider: StubSpeechProvider
    ) async throws -> TranscriptionCoordinator {
        let appleSpeech = AppleSpeechCoordinator(
            provider: ReadyAppleSpeechProvider(),
            selectedLocaleIdentifier: "en_US",
            persistSelection: { _ in }
        )
        await appleSpeech.refresh()
        return TranscriptionCoordinator(
            keychain: StaticCredentialStore(),
            appleSpeech: appleSpeech,
            connectivity: StaticConnectivityMonitor(state: connectivity),
            provider: { _ in cloudProvider }
        )
    }

    private func makeModel(
        provider: any LocalSpeechTranscribing,
        fallbackEnabled: Bool = false
    ) throws -> (AppModel, UserDefaults, String) {
        let suiteName = "ai.dictator.tests.offline.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(true, forKey: "onboardingComplete")
        defaults.set(ProviderKind.groq.rawValue, forKey: "selectedSTT")
        defaults.set(fallbackEnabled, forKey: "offlineFallbackEnabled")
        return (
            AppModel(
                keychain: EmptyCredentialStore(),
                appleSpeechProvider: provider,
                defaults: defaults,
                connectivity: StaticConnectivityMonitor(state: .online)
            ),
            defaults,
            suiteName
        )
    }
}

private extension TranscriptionResult {
    static let cloud = TranscriptionResult(
        text: "cloud",
        provider: .groq,
        model: "cloud-model",
        latency: 0
    )
}

private struct StaticCredentialStore: CredentialStoring {
    func save(_ credentials: ProviderCredentials, for purpose: ProviderPurpose, provider: ProviderKind) throws {}
    func load(for purpose: ProviderPurpose, provider: ProviderKind) throws -> ProviderCredentials? {
        .init(apiKey: "test")
    }
}

private struct EmptyCredentialStore: CredentialStoring {
    func save(_ credentials: ProviderCredentials, for purpose: ProviderPurpose, provider: ProviderKind) throws {}
    func load(for purpose: ProviderPurpose, provider: ProviderKind) throws -> ProviderCredentials? { nil }
}

private enum TestCredentialError: Error { case denied }

private struct FailingMigrationCredentialStore: CredentialStoring {
    func save(_ credentials: ProviderCredentials, for purpose: ProviderPurpose, provider: ProviderKind) throws {
        throw TestCredentialError.denied
    }

    func load(for purpose: ProviderPurpose, provider: ProviderKind) throws -> ProviderCredentials? {
        purpose == .speechToText && provider == .groq ? .init(apiKey: "speech") : nil
    }
}

private struct StaticConnectivityMonitor: ConnectivityMonitoring {
    let state: ConnectivityState
}

private struct StubSpeechProvider: SpeechToTextProvider {
    let metadata = GroqSTTProvider().metadata
    let result: TranscriptionResult?
    let error: (any Error)?

    init(result: TranscriptionResult) {
        self.result = result
        error = nil
    }

    init(error: any Error) {
        result = nil
        self.error = error
    }

    func validate(credentials: ProviderCredentials) async throws {}
    func listModels(credentials: ProviderCredentials) async throws -> [String] { metadata.models }
    func transcribe(
        audio: RecordedAudio,
        options: TranscriptionOptions,
        credentials: ProviderCredentials
    ) async throws -> TranscriptionResult {
        if let error { throw error }
        guard let result else { throw ProviderError.invalidResponse }
        return result
    }
}

private actor ReadyAppleSpeechProvider: LocalSpeechTranscribing {
    private let locales = [
        AppleSpeechLocale(identifier: "en_US", engine: .speechTranscriber),
        AppleSpeechLocale(identifier: "fr_FR", engine: .speechTranscriber),
    ]

    func availableLocales() async -> [AppleSpeechLocale] { locales }
    func readiness(for localeIdentifier: String) async -> AppleSpeechReadiness {
        .ready(.init(identifier: localeIdentifier, engine: .speechTranscriber))
    }
    func installAssets(
        for localeIdentifier: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> AppleSpeechReadiness {
        .ready(.init(identifier: localeIdentifier, engine: .speechTranscriber))
    }
    func transcribe(
        audio: RecordedAudio,
        localeIdentifier: String,
        vocabulary: [VocabularyEntry]
    ) async throws -> TranscriptionResult {
        .init(
            text: "apple",
            language: localeIdentifier,
            provider: .appleSpeech,
            model: AppleTranscriptionEngine.speechTranscriber.rawValue,
            latency: 0
        )
    }
}

private actor UnavailableAppleSpeechProvider: LocalSpeechTranscribing {
    func availableLocales() async -> [AppleSpeechLocale] { [] }
    func readiness(for localeIdentifier: String) async -> AppleSpeechReadiness {
        .unavailable("No Apple speech languages are available on this Mac.")
    }
    func installAssets(
        for localeIdentifier: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> AppleSpeechReadiness {
        .unavailable("No Apple speech languages are available on this Mac.")
    }
    func transcribe(
        audio: RecordedAudio,
        localeIdentifier: String,
        vocabulary: [VocabularyEntry]
    ) async throws -> TranscriptionResult {
        throw ProviderError.unsupported("Unavailable")
    }
}
