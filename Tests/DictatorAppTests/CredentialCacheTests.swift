import DictatorCore
import Foundation
import XCTest
@testable import Dictator

@MainActor
final class CredentialCacheTests: XCTestCase {
    func testRepeatedReadsHitTheKeychainOnce() throws {
        let suiteName = "ai.dictator.tests.credential-cache.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = CountingCredentialStore()
        try store.save(.init(apiKey: "first"), for: .speechToText, provider: .groq)

        let model = AppModel(keychain: store, appleSpeechProvider: nil, defaults: defaults)

        XCTAssertEqual(model.credentials(purpose: .speechToText, provider: .groq)?.apiKey, "first")
        XCTAssertEqual(model.credentials(purpose: .speechToText, provider: .groq)?.apiKey, "first")
        XCTAssertEqual(store.loadCount, 1)
    }

    func testMissingCredentialsAreCachedAsNegativeResults() throws {
        let suiteName = "ai.dictator.tests.credential-cache-miss.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = CountingCredentialStore()

        let model = AppModel(keychain: store, appleSpeechProvider: nil, defaults: defaults)

        XCTAssertNil(model.credentials(purpose: .speechToText, provider: .deepgram))
        XCTAssertNil(model.credentials(purpose: .speechToText, provider: .deepgram))
        XCTAssertEqual(store.loadCount, 1)
    }

    func testSavingCredentialsInvalidatesTheCache() throws {
        let suiteName = "ai.dictator.tests.credential-cache-invalidate.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = CountingCredentialStore()
        try store.save(.init(apiKey: "first"), for: .speechToText, provider: .groq)

        let model = AppModel(keychain: store, appleSpeechProvider: nil, defaults: defaults)

        XCTAssertEqual(model.credentials(purpose: .speechToText, provider: .groq)?.apiKey, "first")
        XCTAssertEqual(store.loadCount, 1)

        try model.saveCredentials(
            .init(apiKey: "second"),
            purpose: .speechToText,
            provider: .groq,
            model: "whisper-large-v3-turbo"
        )

        XCTAssertEqual(model.credentials(purpose: .speechToText, provider: .groq)?.apiKey, "second")
        XCTAssertEqual(store.loadCount, 2)
    }

    func testSelectingSTTInvalidatesStaleCleanupCredentialCache() throws {
        let suiteName = "ai.dictator.tests.credential-cache-stt-select.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = CountingCredentialStore()

        let model = AppModel(keychain: store, appleSpeechProvider: nil, defaults: defaults)
        try model.selectSTT(.appleSpeech)

        // No Groq STT key is saved yet, and cleanup credentials never fall
        // back while the selected STT provider is Apple.
        XCTAssertNil(model.credentials(purpose: .cleanup, provider: .groq))

        try store.save(.init(apiKey: "groq-stt-key"), for: .speechToText, provider: .groq)
        try model.selectSTT(.groq)

        // Without invalidating the cache, this would still return the stale
        // nil resolved while the selected STT was Apple.
        XCTAssertEqual(model.credentials(purpose: .cleanup, provider: .groq)?.apiKey, "groq-stt-key")
    }

    func testStartDictationWarmsUpTheSelectedSTTProvider() async throws {
        let suiteName = "ai.dictator.tests.stt-warmup.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let warmed = expectation(description: "STT warm-up requested")
        let store = StaticCredentialStore()
        let appleSpeech = AppleSpeechCoordinator(
            provider: nil, selectedLocaleIdentifier: "en_US", persistSelection: { _ in }
        )
        let coordinator = TranscriptionCoordinator(
            keychain: store,
            appleSpeech: appleSpeech,
            provider: { _ in WarmUpTrackingSTTProvider(onWarmUp: { warmed.fulfill() }) }
        )
        let recorder = TestAudioRecorder()

        let model = AppModel(
            keychain: store,
            appleSpeechProvider: nil,
            defaults: defaults,
            recorder: recorder,
            transcriptionCoordinator: coordinator
        )

        await model.startDictation()

        await fulfillment(of: [warmed], timeout: 1)
    }
}

private final class CountingCredentialStore: CredentialStoring, @unchecked Sendable {
    private(set) var loadCount = 0
    private var values: [String: ProviderCredentials] = [:]

    func save(_ credentials: ProviderCredentials, for purpose: ProviderPurpose, provider: ProviderKind) throws {
        values["\(purpose.rawValue).\(provider.rawValue)"] = credentials
    }

    func load(for purpose: ProviderPurpose, provider: ProviderKind) throws -> ProviderCredentials? {
        loadCount += 1
        return values["\(purpose.rawValue).\(provider.rawValue)"]
    }
}

private struct StaticCredentialStore: CredentialStoring {
    func save(_ credentials: ProviderCredentials, for purpose: ProviderPurpose, provider: ProviderKind) throws {}
    func load(for purpose: ProviderPurpose, provider: ProviderKind) throws -> ProviderCredentials? {
        .init(apiKey: "test")
    }
}

private struct WarmUpTrackingSTTProvider: SpeechToTextProvider {
    let metadata = GroqSTTProvider().metadata
    let onWarmUp: @Sendable () -> Void

    func validate(credentials: ProviderCredentials) async throws {}
    func transcribe(audio: RecordedAudio, options: TranscriptionOptions, credentials: ProviderCredentials) async throws -> TranscriptionResult {
        .init(text: "test", provider: .groq, model: "test", latency: 0)
    }
    func warmUpConnection(credentials: ProviderCredentials) async { onWarmUp() }
}
