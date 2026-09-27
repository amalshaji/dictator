import DictatorCore
import Foundation
import XCTest
@testable import Dictator

@MainActor
final class HomePresentationTests: XCTestCase {
    func testHomeHeaderTitleMapsDictationPhaseToState() {
        XCTAssertEqual(HomeHeaderPresentation.title(for: .idle), "Ready")
        XCTAssertEqual(HomeHeaderPresentation.title(for: .listening), "Listening…")
        XCTAssertEqual(HomeHeaderPresentation.title(for: .processing), "Transcribing…")
    }

    func testTranscriptRowFormatterUsesOnlyTheFirstLineOfFinalText() {
        XCTAssertEqual(TranscriptRowFormatter.firstLine(of: "Hello"), "Hello")
        XCTAssertEqual(TranscriptRowFormatter.firstLine(of: "Hello\nworld"), "Hello")
        XCTAssertEqual(TranscriptRowFormatter.firstLine(of: "Hello\nworld\nagain"), "Hello")
    }

    func testTranscriptRowFormatterProducesARelativeTimeString() {
        let now = Date(timeIntervalSince1970: 1_000)
        let twoMinutesAgo = now.addingTimeInterval(-120)

        let relative = TranscriptRowFormatter.relativeTime(from: twoMinutesAgo, relativeTo: now)

        XCTAssertTrue(relative.contains("2"))
    }

    func testHomeActivityBuildsSevenChronologicalDayBuckets() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 21, hour: 12
        )))
        let firstDay = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 15, hour: 9
        )))
        let today = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 21, hour: 10
        )))
        let transcripts = [
            TranscriptRecord(
                createdAt: firstDay, rawText: "one", finalText: "one",
                sttProvider: .groq, sttModel: "whisper", audioDuration: 90,
                sttLatency: 0.1, insertionOutcome: "inserted"
            ),
            TranscriptRecord(
                createdAt: today, rawText: "two", finalText: "two",
                sttProvider: .groq, sttModel: "whisper", audioDuration: 30,
                sttLatency: 0.1, insertionOutcome: "inserted"
            ),
        ]

        let activity = HomeDashboardAnalytics.activity(
            in: transcripts,
            endingAt: now,
            calendar: calendar
        )

        XCTAssertEqual(activity.count, 7)
        XCTAssertEqual(activity.map(\.date), activity.map(\.date).sorted())
        XCTAssertEqual(activity.first?.speechMinutes, 1.5)
        XCTAssertEqual(activity.last?.speechMinutes, 0.5)
        XCTAssertEqual(activity.dropFirst().dropLast().map(\.speechMinutes), Array(repeating: 0, count: 5))
    }

    func testHomeFormattedSpokenTimeUsesLargestNaturalUnits() {
        XCTAssertEqual(HomeDashboardAnalytics.formattedSpokenTime(0), "0 sec")
        XCTAssertEqual(HomeDashboardAnalytics.formattedSpokenTime(45), "45 sec")
        XCTAssertEqual(HomeDashboardAnalytics.formattedSpokenTime(60), "1 min")
        XCTAssertEqual(HomeDashboardAnalytics.formattedSpokenTime(752), "12 min")
        XCTAssertEqual(HomeDashboardAnalytics.formattedSpokenTime(7_200), "2 hr")
        XCTAssertEqual(HomeDashboardAnalytics.formattedSpokenTime(4 * 3_600 + 23 * 60), "4 hr 23 min")
    }

    func testHomeTranscriptSearchMatchesFinalTextRawTextAndSourceApp() {
        let launch = TranscriptRecord(
            createdAt: Date(timeIntervalSince1970: 300),
            rawText: "Plan the August launch", finalText: "Plan the August launch",
            sttProvider: .groq, sttModel: "whisper", sourceBundleID: "com.apple.mail",
            audioDuration: 1, sttLatency: 0.1, insertionOutcome: "inserted"
        )
        let notes = TranscriptRecord(
            createdAt: Date(timeIntervalSince1970: 200),
            rawText: "Capture café notes", finalText: "Capture café notes",
            sttProvider: .groq, sttModel: "whisper", sourceBundleID: "com.apple.Notes",
            audioDuration: 1, sttLatency: 0.1, insertionOutcome: "inserted"
        )

        XCTAssertEqual(
            HomeDashboardAnalytics.transcripts(matching: "AUGUST", in: [notes, launch]).map(\.id),
            [launch.id]
        )
        XCTAssertEqual(
            HomeDashboardAnalytics.transcripts(matching: "cafe", in: [notes, launch]).map(\.id),
            [notes.id]
        )
        XCTAssertEqual(
            HomeDashboardAnalytics.transcripts(matching: "mail", in: [notes, launch]).map(\.id),
            [launch.id]
        )
    }
}
