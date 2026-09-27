import DictatorCore
import XCTest

final class TranscriptUsageModelsTests: XCTestCase {
    func testLLMExecutionRoundTripsThroughCanonicalLLMField() throws {
        let execution = LLMExecution(
            provider: .groq,
            model: "meta-llama/llama-4-scout-17b-16e-instruct",
            latency: 0.4,
            usage: .init(inputTokens: 120, outputTokens: 18)
        )
        let record = TranscriptRecord(
            rawText: "Reply to this email",
            finalText: "Hi Sam,\n\nTuesday works for me.",
            sttProvider: .groq,
            sttModel: "whisper-large-v3-turbo",
            audioDuration: 2,
            sttLatency: 0.2,
            llmExecution: execution,
            insertionOutcome: "typed"
        )

        let data = try JSONEncoder().encode(record)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object["llmExecution"] as? [String: Any])

        let decoded = try JSONDecoder().decode(TranscriptRecord.self, from: data)
        XCTAssertEqual(decoded.llmExecution, execution)
        XCTAssertEqual(decoded, record)
    }

    func testAppleFallbackEngineProvenanceRoundTrips() throws {
        let record = TranscriptRecord(
            rawText: "native",
            finalText: "native",
            sttProvider: .appleSpeech,
            sttModel: AppleTranscriptionEngine.dictationTranscriber.rawValue,
            sttLocale: "en_IN",
            audioDuration: 1,
            sttLatency: 0.2,
            insertionOutcome: "typed"
        )

        let decoded = try JSONDecoder().decode(
            TranscriptRecord.self,
            from: JSONEncoder().encode(record)
        )

        XCTAssertEqual(decoded.sttProvider, .appleSpeech)
        XCTAssertEqual(decoded.sttModel, AppleTranscriptionEngine.dictationTranscriber.rawValue)
        XCTAssertEqual(decoded.sttLocale, "en_IN")
    }
}
