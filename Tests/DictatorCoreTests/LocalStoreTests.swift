import XCTest
@testable import DictatorCore

final class LocalStoreTests: XCTestCase {
    func testLifetimeStatisticsAccumulateCompletedDictations() {
        var statistics = LifetimeStatistics()
        statistics.record(TranscriptRecord(
            rawText: "one two",
            finalText: "One two three",
            sttProvider: .groq,
            sttModel: "whisper",
            audioDuration: 2,
            sttLatency: 0.1,
            pipelineLatency: 0.4,
            insertionOutcome: "typed"
        ))
        statistics.record(TranscriptRecord(
            rawText: "four five",
            finalText: "Four five",
            sttProvider: .groq,
            sttModel: "whisper",
            audioDuration: 3,
            sttLatency: 0.1,
            pipelineLatency: 0.6,
            insertionOutcome: "typed"
        ))

        XCTAssertEqual(statistics.dictations, 2)
        XCTAssertEqual(statistics.words, 5)
        XCTAssertEqual(statistics.audioSeconds, 5)
        XCTAssertEqual(statistics.averageWPM, 60)
        XCTAssertEqual(statistics.averagePipelineLatency, 0.5)
    }

    func testLifetimeStatisticsPersistIndependentlyOfTranscriptRetention() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "data.json")
        let store = LocalStore(fileURL: url)
        let now = Date()
        let oldTranscript = TranscriptRecord(
            createdAt: now.addingTimeInterval(-40 * 86_400),
            rawText: "old",
            finalText: "Old transcript",
            sttProvider: .groq,
            sttModel: "whisper",
            audioDuration: 2,
            sttLatency: 0.1,
            pipelineLatency: 0.4,
            insertionOutcome: "typed"
        )
        var statistics = LifetimeStatistics()
        statistics.record(oldTranscript)

        try await store.save(PersistedData(
            transcripts: [oldTranscript],
            lifetimeStatistics: statistics
        ), now: now)
        let loaded = try await store.load()

        XCTAssertTrue(loaded.transcripts.isEmpty)
        XCTAssertEqual(loaded.lifetimeStatistics, statistics)
    }

    func testLegacyPersistedDataDefaultsLifetimeStatisticsToZero() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "transcripts": [],
            "vocabulary": [],
            "clipboard": [],
            "styles": [],
            "snippets": []
        ])

        let decoded = try JSONDecoder().decode(PersistedData.self, from: data)

        XCTAssertEqual(decoded.lifetimeStatistics, LifetimeStatistics())
    }

    func testLoadDropsTranscriptsWithRetiredProviderKinds() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "data.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = """
        {
            "transcripts": [
                {
                    "id": "\(UUID().uuidString)",
                    "createdAt": "2026-01-01T00:00:00Z",
                    "rawText": "valid",
                    "finalText": "Valid",
                    "sttProvider": "groq",
                    "sttModel": "whisper",
                    "audioDuration": 1,
                    "sttLatency": 0.1,
                    "insertionOutcome": "typed"
                },
                {
                    "id": "\(UUID().uuidString)",
                    "createdAt": "2026-01-01T00:00:00Z",
                    "rawText": "retired",
                    "finalText": "Retired",
                    "sttProvider": "gladia",
                    "sttModel": "solaria-1",
                    "audioDuration": 1,
                    "sttLatency": 0.1,
                    "insertionOutcome": "typed"
                }
            ]
        }
        """
        try json.data(using: .utf8)!.write(to: url)
        let store = LocalStore(fileURL: url)

        let loaded = try await store.load()

        XCTAssertEqual(loaded.transcripts.count, 1)
        XCTAssertEqual(loaded.transcripts.first?.rawText, "valid")
    }
}
