import Foundation
import XCTest
@testable import DictatorCore

final class LiveProviderTests: XCTestCase {
    func testSameAudioAcrossEveryConfiguredSTTProvider() async throws {
        let environment = EnvironmentLoader.load()
        let audio = try referenceAudio()
        let configurations: [(ProviderKind, ProviderCredentials)] = [
            (.groq, .init(apiKey: environment["GROQ_API_KEY"] ?? "")),
            (.cloudflare, .init(apiKey: environment["CLOUDFLARE_API_TOKEN"] ?? "", accountID: environment["CLOUDFLARE_ACCOUNT_ID"])),
            (.xAI, .init(apiKey: environment["XAI_API_KEY"] ?? "")),
            (.deepgram, .init(apiKey: environment["DEEPGRAM_API_KEY"] ?? "")),
            (.assemblyAI, .init(apiKey: environment["ASSEMBLYAI_API_KEY"] ?? "")),
            (.gladia, .init(apiKey: environment["GLADIA_API_KEY"] ?? ""))
        ]

        var tested = 0
        for (kind, credentials) in configurations where !credentials.apiKey.isEmpty {
            guard let provider = ProviderRegistry.sttProvider(for: kind) else { continue }
            let result = try await provider.transcribe(
                audio: audio,
                options: .init(model: provider.metadata.defaultModel, language: "en", vocabulary: [.init(value: "Dictator")]),
                credentials: credentials
            )
            XCTAssertFalse(result.text.isEmpty, "\(kind.rawValue) returned no text")
            XCTAssertGreaterThan(result.latency, 0)
            tested += 1
        }
        if tested == 0 { throw XCTSkip("No live STT credentials were found in .env") }
    }

    func testSameTranscriptAcrossEveryConfiguredCleanupProvider() async throws {
        let environment = EnvironmentLoader.load()
        let raw = "Um, Dictator version 2.4 is at https://example.com, and and it works."
        let configurations: [(ProviderKind, ProviderCredentials)] = [
            (.groq, .init(apiKey: environment["GROQ_API_KEY"] ?? "")),
            (.cloudflare, .init(apiKey: environment["CLOUDFLARE_API_TOKEN"] ?? "", accountID: environment["CLOUDFLARE_ACCOUNT_ID"])),
            (.gemini, .init(apiKey: environment["GEMINI_API_KEY"] ?? "")),
            (.xAI, .init(apiKey: environment["XAI_API_KEY"] ?? "")),
            (.openRouter, .init(apiKey: environment["OPENROUTER_API_KEY"] ?? ""))
        ]
        var tested = 0
        for (kind, credentials) in configurations where !credentials.apiKey.isEmpty {
            guard let provider = CleanupProviderRegistry.provider(for: kind) else { continue }
            let result = try await provider.clean(
                request: .init(input: .transcription(raw), vocabulary: [.init(value: "Dictator")]),
                model: provider.metadata.defaultModel,
                credentials: credentials
            )
            XCTAssertTrue(result.text.contains("Dictator"))
            XCTAssertTrue(result.text.contains("2.4"))
            XCTAssertTrue(result.text.contains("https://example.com"))
            tested += 1
        }
        if tested == 0 { throw XCTSkip("No live LLM credentials were found in .env") }
    }

    private func referenceAudio() throws -> RecordedAudio {
        guard let bundleURL = Bundle(for: Self.self).url(forResource: "reference", withExtension: "wav") else {
            XCTFail("reference.wav was not copied into the integration test bundle")
            throw CocoaError(.fileNoSuchFile)
        }
        let wav = try Data(contentsOf: bundleURL)
        let pcm = wav.count > 44 ? wav.dropFirst(44) : Data()
        return RecordedAudio(wavData: wav, duration: Double(pcm.count) / 2 / 16_000)
    }
}

private enum EnvironmentLoader {
    static func load() -> [String: String] {
        var result = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let contents = try? String(contentsOf: root.appending(path: ".env"), encoding: .utf8) else { return result }
        for line in contents.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let separator = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            result[key] = value
        }
        return result
    }
}
