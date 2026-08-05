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

    func testStorePersistsAndPrunesPrivateClipboard() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "data.json")
        let store = LocalStore(fileURL: url)
        let old = ClipboardEntry(createdAt: Date(timeIntervalSinceNow: -40 * 86_400), text: "old", rawText: "old")
        let recent = (0..<55).map { ClipboardEntry(createdAt: Date(timeIntervalSinceNow: TimeInterval(-$0)), text: "item \($0)", rawText: "item \($0)") }
        try await store.save(PersistedData(clipboard: [old] + recent))
        let loaded = try await store.load()
        XCTAssertEqual(loaded.clipboard.count, 50)
        XCTAssertFalse(loaded.clipboard.contains { $0.text == "old" })
    }
}
