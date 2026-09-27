import DictatorCore
import Foundation
import XCTest
@testable import Dictator

@MainActor
final class OfflineDictationTests: XCTestCase {
    private let audio = RecordedAudio(wavData: Data(), duration: 1)

    func testCloudTransportFailureFallsBackToAppleWhenReady() async throws {
        // The coordinator, not the test, must trigger readiness. The fake starts
        // in the default `.checking` state and only reports `.ready` once refreshed.
        let appleSpeech = AppleSpeechCoordinator(
            provider: ReadyAppleSpeechProvider(), selectedLocaleIdentifier: "en_US", persistSelection: { _ in }
        )
        let coordinator = TranscriptionCoordinator(
            keychain: StaticCredentialStore(),
            appleSpeech: appleSpeech,
            provider: { _ in StubSpeechProvider(error: ProviderError.transport(.notConnectedToInternet)) }
        )

        let run = try await coordinator.transcribe(
            audio: audio, selectedProvider: .groq, selectedModel: "cloud-model", vocabulary: []
        )

        XCTAssertEqual(run.result.provider, .appleSpeech)
        XCTAssertTrue(run.usedAppleFallback)
        XCTAssertFalse(run.allowsCleanup)
    }

    func testCloudTransportFailurePropagatesWhenAppleIsNotReady() async throws {
        let appleSpeech = AppleSpeechCoordinator(
            provider: UnavailableAppleSpeechProvider(), selectedLocaleIdentifier: "en_US", persistSelection: { _ in }
        )
        await appleSpeech.refresh()
        let coordinator = TranscriptionCoordinator(
            keychain: StaticCredentialStore(),
            appleSpeech: appleSpeech,
            provider: { _ in StubSpeechProvider(error: ProviderError.transport(.notConnectedToInternet)) }
        )

        do {
            _ = try await coordinator.transcribe(
                audio: audio, selectedProvider: .groq, selectedModel: "cloud-model", vocabulary: []
            )
            XCTFail("Expected the cloud transport error to propagate")
        } catch {
            XCTAssertEqual(TransportFailureClassifier.code(for: error), .notConnectedToInternet)
        }
    }

    func testCloudTransportFailureStillRetriesWhenAppleIsNotReady() async throws {
        let appleSpeech = AppleSpeechCoordinator(
            provider: UnavailableAppleSpeechProvider(), selectedLocaleIdentifier: "en_US", persistSelection: { _ in }
        )
        await appleSpeech.refresh()
        let counter = CallCounter()
        let coordinator = TranscriptionCoordinator(
            keychain: StaticCredentialStore(),
            appleSpeech: appleSpeech,
            provider: { _ in CountingStubSpeechProvider(error: ProviderError.transport(.notConnectedToInternet), counter: counter) }
        )

        do {
            _ = try await coordinator.transcribe(
                audio: audio, selectedProvider: .groq, selectedModel: "cloud-model", vocabulary: []
            )
            XCTFail("Expected the cloud transport error to propagate")
        } catch {
            XCTAssertEqual(TransportFailureClassifier.code(for: error), .notConnectedToInternet)
        }

        // TranscriptionCoordinator has no injectable retry delay, so this only
        // confirms the retry policy still ran rather than pinning an exact count.
        let calls = await counter.count
        XCTAssertGreaterThan(calls, 1, "Transient transport errors should still be retried when Apple is not ready")
    }
}

private struct StaticCredentialStore: CredentialStoring {
    func save(_ credentials: ProviderCredentials, for purpose: ProviderPurpose, provider: ProviderKind) throws {}
    func load(for purpose: ProviderPurpose, provider: ProviderKind) throws -> ProviderCredentials? { .init(apiKey: "test") }
}

private struct StubSpeechProvider: SpeechToTextProvider {
    let metadata = GroqSTTProvider().metadata
    let error: any Error

    func validate(credentials: ProviderCredentials) async throws {}
    func transcribe(audio: RecordedAudio, options: TranscriptionOptions, credentials: ProviderCredentials) async throws -> TranscriptionResult {
        throw error
    }
}

private actor CallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

private struct CountingStubSpeechProvider: SpeechToTextProvider {
    let metadata = GroqSTTProvider().metadata
    let error: any Error
    let counter: CallCounter

    func validate(credentials: ProviderCredentials) async throws {}
    func transcribe(audio: RecordedAudio, options: TranscriptionOptions, credentials: ProviderCredentials) async throws -> TranscriptionResult {
        await counter.increment()
        throw error
    }
}

private actor ReadyAppleSpeechProvider: LocalSpeechTranscribing {
    private let locale = AppleSpeechLocale(identifier: "en_US", engine: .speechTranscriber)

    func availableLocales() async -> [AppleSpeechLocale] { [locale] }
    func readiness(for localeIdentifier: String) async -> AppleSpeechReadiness { .ready(locale) }
    func installAssets(for localeIdentifier: String, progress: @escaping @Sendable (Double) -> Void) async throws -> AppleSpeechReadiness { .ready(locale) }
    func transcribe(audio: RecordedAudio, localeIdentifier: String, vocabulary: [VocabularyEntry]) async throws -> TranscriptionResult {
        .init(text: "apple", language: localeIdentifier, provider: .appleSpeech, model: "speech-transcriber", latency: 0)
    }
}

private actor UnavailableAppleSpeechProvider: LocalSpeechTranscribing {
    func availableLocales() async -> [AppleSpeechLocale] { [] }
    func readiness(for localeIdentifier: String) async -> AppleSpeechReadiness { .unavailable("No Apple speech languages are available on this Mac.") }
    func installAssets(for localeIdentifier: String, progress: @escaping @Sendable (Double) -> Void) async throws -> AppleSpeechReadiness { .unavailable("No Apple speech languages are available on this Mac.") }
    func transcribe(audio: RecordedAudio, localeIdentifier: String, vocabulary: [VocabularyEntry]) async throws -> TranscriptionResult {
        throw ProviderError.unsupported("Unavailable")
    }
}
