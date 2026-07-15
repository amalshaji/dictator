@preconcurrency import AVFoundation
import XCTest
@testable import DictatorCore

final class CoreTests: XCTestCase {
    func testWAVEncoderBuildsValidHeader() {
        let pcm = Data([0, 0, 255, 127, 0, 128])
        let wav = WAVEncoder.encodePCM16(pcm)
        XCTAssertEqual(String(data: wav[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: wav[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: wav[36..<40], encoding: .ascii), "data")
        XCTAssertEqual(wav.count, 44 + pcm.count)
    }

    @available(macOS 26.0, *)
    func testAppleSpeechConvertsRecordedPCMEntirelyInMemory() throws {
        let pcm = Data(repeating: 0, count: 3_200)
        let source = try AppleSpeechTranscriber.pcmBuffer(from: WAVEncoder.encodePCM16(pcm))
        let targetFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        ))
        let converted = try AppleSpeechTranscriber.convert(source, to: targetFormat)

        XCTAssertEqual(source.format.sampleRate, 16_000)
        XCTAssertEqual(source.frameLength, 1_600)
        XCTAssertEqual(converted.format, targetFormat)
        XCTAssertGreaterThan(converted.frameLength, source.frameLength)
    }

    func testRegistriesExposeAllPlannedProviders() {
        XCTAssertEqual(Set(ProviderRegistry.sttMetadata.map(\.kind)), Set([.groq, .cloudflare, .xAI, .deepgram, .assemblyAI, .gladia]))
        XCTAssertEqual(Set(CleanupProviderRegistry.metadata.map(\.kind)), Set([.groq, .cloudflare, .gemini, .xAI, .openRouter, .openAICompatible]))
        XCTAssertEqual(Set(ScreenAwareProviderRegistry.metadata.map(\.kind)), Set([.groq, .gemini, .xAI, .openRouter, .openAICompatible]))
        XCTAssertNil(ScreenAwareProviderRegistry.provider(for: .cloudflare))
    }

    func testScreenAwareCapabilityRequiresProofForUnknownModels() {
        XCTAssertEqual(ScreenAwareModelCapabilities.capability(provider: .gemini, model: "gemini-2.5-flash-lite"), .supported)
        XCTAssertEqual(ScreenAwareModelCapabilities.capability(provider: .groq, model: "openai/gpt-oss-20b"), .unsupported)
        XCTAssertEqual(ScreenAwareModelCapabilities.capability(provider: .openAICompatible, model: "vision-model"), .requiresConfirmation)
    }

    func testSTTCatalogIncludesAppleOnlyWhenTheOSSupportsIt() {
        XCTAssertEqual(
            ProviderRegistry.sttMetadata(includeAppleSpeech: false).map(\.kind),
            [.groq, .cloudflare, .xAI, .deepgram, .assemblyAI, .gladia]
        )
        XCTAssertEqual(
            ProviderRegistry.sttMetadata(includeAppleSpeech: true).map(\.kind),
            [.appleSpeech, .groq, .cloudflare, .xAI, .deepgram, .assemblyAI, .gladia]
        )
    }

    func testNewInstallDefaultsToAppleOnlyWhenAvailable() {
        XCTAssertEqual(STTProviderSelection.resolve(savedRawValue: nil, appleSpeechAvailable: true), .appleSpeech)
        XCTAssertEqual(STTProviderSelection.resolve(savedRawValue: nil, appleSpeechAvailable: false), .groq)
    }

    func testUpgradePreservesSavedCloudProvider() {
        XCTAssertEqual(STTProviderSelection.resolve(savedRawValue: "deepgram", appleSpeechAvailable: true), .deepgram)
        XCTAssertEqual(
            STTProviderSelection.resolve(
                savedRawValue: nil,
                appleSpeechAvailable: true,
                existingInstallation: true
            ),
            .groq
        )
    }

    func testDowngradeReplacesSavedAppleProviderWithLastCloudProvider() {
        XCTAssertEqual(
            STTProviderSelection.resolve(
                savedRawValue: ProviderKind.appleSpeech.rawValue,
                appleSpeechAvailable: false,
                lastCloudRawValue: ProviderKind.xAI.rawValue
            ),
            .xAI
        )
        XCTAssertEqual(
            STTProviderSelection.resolve(
                savedRawValue: ProviderKind.appleSpeech.rawValue,
                appleSpeechAvailable: false,
                lastCloudRawValue: nil
            ),
            .groq
        )
    }

    func testSwitchingToApplePreservesCredentialReusedByCleanup() throws {
        let store = InMemoryCredentialStore()
        let shared = ProviderCredentials(apiKey: "shared-key")
        try store.save(shared, for: .speechToText, provider: .groq)

        try CredentialReuseMigration.preserveCleanupCredential(
            previousSTT: .groq,
            selectedCleanup: .groq,
            store: store
        )

        XCTAssertEqual(try store.load(for: .cleanup, provider: .groq), shared)
        XCTAssertEqual(try store.load(for: .speechToText, provider: .groq), shared)
    }

    func testSwitchingToAppleDoesNotOverwriteDedicatedCleanupCredential() throws {
        let store = InMemoryCredentialStore()
        try store.save(.init(apiKey: "speech"), for: .speechToText, provider: .groq)
        try store.save(.init(apiKey: "cleanup"), for: .cleanup, provider: .groq)

        try CredentialReuseMigration.preserveCleanupCredential(
            previousSTT: .groq,
            selectedCleanup: .groq,
            store: store
        )

        XCTAssertEqual(try store.load(for: .cleanup, provider: .groq)?.apiKey, "cleanup")
    }

    func testPreparingAppleSwitchCapturesPreviousCloudProvider() throws {
        let store = InMemoryCredentialStore()

        let lastCloud = try STTProviderSelection.prepareTransition(
            from: .deepgram,
            to: .appleSpeech,
            selectedCleanup: .groq,
            store: store
        )

        XCTAssertEqual(lastCloud, .deepgram)
    }

    func testPreparingAppleSwitchFailsBeforeSelectionWhenCredentialCopyFails() throws {
        let store = InMemoryCredentialStore(saveError: TestCredentialError.denied)
        try store.saveInitial(.init(apiKey: "shared"), for: .speechToText, provider: .groq)

        XCTAssertThrowsError(
            try STTProviderSelection.prepareTransition(
                from: .groq,
                to: .appleSpeech,
                selectedCleanup: .groq,
                store: store
            )
        )
    }
}

private final class InMemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private var values: [String: ProviderCredentials] = [:]
    private let saveError: Error?

    init(saveError: Error? = nil) {
        self.saveError = saveError
    }

    func save(_ credentials: ProviderCredentials, for purpose: ProviderPurpose, provider: ProviderKind) throws {
        if let saveError { throw saveError }
        try saveInitial(credentials, for: purpose, provider: provider)
    }

    func saveInitial(_ credentials: ProviderCredentials, for purpose: ProviderPurpose, provider: ProviderKind) throws {
        values["\(purpose.rawValue).\(provider.rawValue)"] = credentials
    }

    func load(for purpose: ProviderPurpose, provider: ProviderKind) throws -> ProviderCredentials? {
        values["\(purpose.rawValue).\(provider.rawValue)"]
    }
}

private enum TestCredentialError: Error {
    case denied
}
