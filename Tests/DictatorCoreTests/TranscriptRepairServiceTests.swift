import XCTest
@testable import DictatorCore

final class TranscriptRepairServiceTests: XCTestCase {
    func testReprocessingStartsFromRawTextAndLeavesOriginalRecordUnchanged() async throws {
        let record = TranscriptRecord(
            rawText: "dictater",
            finalText: "Unrelated current result",
            sttProvider: .groq,
            sttModel: "whisper-large-v3-turbo",
            audioDuration: 1,
            sttLatency: 0.1,
            pipelineLatency: 0.2,
            insertionOutcome: "typed"
        )

        let revision = try await TranscriptRepairService().reprocess(
            record: record,
            vocabulary: [.init(value: "Dictator", variants: ["dictater"])],
            snippets: [],
            cleanup: nil
        )

        XCTAssertEqual(revision.text, "Dictator")
        XCTAssertEqual(revision.origin, .localProcessing)
        XCTAssertEqual(record.finalText, "Unrelated current result")
        XCTAssertEqual(record.pipelineLatency, 0.2)
    }

    func testCleanupRevisionCarriesTypedProviderExecutionAndSeparateRepairLatency() async throws {
        let record = TranscriptRecord(
            rawText: "hello",
            finalText: "hello",
            sttProvider: .groq,
            sttModel: "whisper-large-v3-turbo",
            audioDuration: 1,
            sttLatency: 0.1,
            insertionOutcome: "typed"
        )
        let cleanup = TranscriptCleanupConfiguration(
            provider: RepairCleanupProvider(),
            model: "repair-model",
            credentials: .init(apiKey: "test")
        )

        let revision = try await TranscriptRepairService().reprocess(
            record: record,
            vocabulary: [],
            snippets: [],
            cleanup: cleanup
        )

        guard case .cleanup(let execution) = revision.origin else {
            return XCTFail("Expected cleanup revision")
        }
        XCTAssertEqual(execution.provider, .groq)
        XCTAssertEqual(execution.model, "repair-model")
        XCTAssertEqual(execution.latency, 0.42)
        XCTAssertEqual(execution.usage?.inputTokens, 8)
        XCTAssertGreaterThanOrEqual(revision.repairLatency, 0)
    }
}

private struct RepairCleanupProvider: CleanupLLMProvider {
    let metadata = ProviderMetadata(kind: .groq, displayName: "Repair", defaultModel: "repair-model", models: ["repair-model"], requiresAccountID: false)
    func validate(credentials: ProviderCredentials) async throws {}
    func listModels(credentials: ProviderCredentials) async throws -> [String] { metadata.models }
    func clean(request: CleanupRequest, model: String, credentials: ProviderCredentials) async throws -> CleanupResult {
        CleanupResult(output: .transcription("Hello."), provider: .groq, model: model, inputTokens: 8, outputTokens: 2, latency: 0.42)
    }
}
