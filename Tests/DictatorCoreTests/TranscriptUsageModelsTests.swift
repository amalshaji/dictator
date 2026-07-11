import DictatorCore
import XCTest

final class TranscriptUsageModelsTests: XCTestCase {
    func testTranscriptEncodesCleanupAsOneExecutionWithoutDuplicatingSTTDuration() throws {
        let cleanup = CleanupExecution(
            provider: .groq,
            model: "openai/gpt-oss-20b",
            latency: 0.2,
            usage: .init(inputTokens: 12, outputTokens: 4)
        )
        let record = TranscriptRecord(
            rawText: "raw",
            finalText: "final",
            sttProvider: .groq,
            sttModel: "whisper-large-v3-turbo",
            sourceBundleID: nil,
            audioDuration: 3,
            sttLatency: 0.1,
            cleanup: cleanup,
            insertionOutcome: "typed"
        )

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        XCTAssertNotNil(object["cleanup"])
        XCTAssertNil(object["llmProvider"])
        XCTAssertNil(object["llmModel"])
        XCTAssertNil(object["cleanupLatency"])
        XCTAssertNil(object["llmUsage"])
        XCTAssertNil(object["sttUsage"])
        XCTAssertEqual(record.sttUsage.audioSeconds, 3)
    }

    func testLegacyTranscriptCleanupFieldsDecodeIntoOneExecution() throws {
        let object: [String: Any] = [
            "id": UUID().uuidString,
            "createdAt": Date().timeIntervalSinceReferenceDate,
            "rawText": "raw",
            "finalText": "final",
            "sttProvider": "groq",
            "sttModel": "whisper-large-v3-turbo",
            "llmProvider": "groq",
            "llmModel": "openai/gpt-oss-20b",
            "audioDuration": 3.0,
            "sttLatency": 0.1,
            "cleanupLatency": 0.2,
            "llmUsage": ["inputTokens": 12, "outputTokens": 4],
            "insertionOutcome": "typed"
        ]

        let record = try JSONDecoder().decode(
            TranscriptRecord.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(record.cleanup?.provider, .groq)
        XCTAssertEqual(record.cleanup?.model, "openai/gpt-oss-20b")
        XCTAssertEqual(record.cleanup?.latency, 0.2)
        XCTAssertEqual(record.cleanup?.usage?.inputTokens, 12)
    }

    func testLegacyCleanupRevisionDecodesTypedProvenance() throws {
        let object: [String: Any] = [
            "id": UUID().uuidString,
            "createdAt": Date().timeIntervalSinceReferenceDate,
            "text": "repaired",
            "origin": "cleanup",
            "llmProvider": "groq",
            "llmModel": "openai/gpt-oss-20b",
            "repairLatency": 0.5,
            "llmUsage": ["inputTokens": 10, "outputTokens": 3]
        ]

        let revision = try JSONDecoder().decode(
            TranscriptRevision.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        guard case .cleanup(let execution) = revision.origin else {
            return XCTFail("Expected typed cleanup provenance")
        }
        XCTAssertEqual(execution.provider, .groq)
        XCTAssertEqual(execution.latency, 0.5)
        XCTAssertEqual(execution.usage?.outputTokens, 3)
    }

    func testPreferredRevisionSuppliesCurrentTextWithoutChangingOriginal() {
        let revision = TranscriptRevision(text: "Repaired", origin: .manual, repairLatency: 0.1)
        let record = TranscriptRecord(
            rawText: "Raw",
            finalText: "Original",
            sttProvider: .groq,
            sttModel: "m",
            audioDuration: 1,
            sttLatency: 0.2,
            pipelineLatency: 0.4,
            insertionOutcome: "typed",
            revisions: [revision],
            preferredRevisionID: revision.id
        )
        XCTAssertEqual(record.currentText, "Repaired")
        XCTAssertEqual(record.rawText, "Raw")
        XCTAssertEqual(record.finalText, "Original")
        XCTAssertEqual(record.pipelineLatency, 0.4)
    }
}
