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
}

private final class InMemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private var values: [String: ProviderCredentials] = [:]

    func save(_ credentials: ProviderCredentials, for purpose: ProviderPurpose, provider: ProviderKind) throws {
        values["\(purpose.rawValue).\(provider.rawValue)"] = credentials
    }

    func load(for purpose: ProviderPurpose, provider: ProviderKind) throws -> ProviderCredentials? {
        values["\(purpose.rawValue).\(provider.rawValue)"]
    }
}
