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

    func testRegistriesExposeAllPlannedProviders() {
        XCTAssertEqual(Set(ProviderRegistry.sttMetadata.map(\.kind)), Set([.groq, .cloudflare, .xAI, .deepgram, .assemblyAI, .gladia]))
        XCTAssertEqual(Set(CleanupProviderRegistry.metadata.map(\.kind)), Set([.groq, .cloudflare, .gemini, .xAI, .openRouter, .openAICompatible]))
    }
}
