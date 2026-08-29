import AppKit
import DictatorCore
import Foundation
import XCTest
@testable import Dictator

@MainActor
final class HomePresentationTests: XCTestCase {
    func testWindowChromeBackgroundMatchesSidebarAndContentAtEveryWidth() throws {
        for width in [920.0, 1_400.0] {
            let image = WindowChromeStyle.backgroundImage(windowWidth: width)
            let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            func color(at point: CGFloat) -> NSColor? {
                let pixel = min(bitmap.pixelsWide - 1, Int(point / image.size.width * CGFloat(bitmap.pixelsWide)))
                return bitmap.colorAt(x: pixel, y: 0)
            }

            XCTAssertEqual(image.size.width, width)
            assertColor(color(at: 0), red: 23, green: 21, blue: 26)
            assertColor(color(at: DictatorDesign.sidebarWidth - 1), red: 23, green: 21, blue: 26)
            assertColor(color(at: DictatorDesign.sidebarWidth), red: 246, green: 244, blue: 240)
            assertColor(color(at: width - 1), red: 246, green: 244, blue: 240)
        }
    }

    func testTranscriptMetadataLabelsSTTProviderAndLatency() {
        let record = TranscriptRecord(
            rawText: "Hello", finalText: "Hello", sttProvider: .groq, sttModel: "whisper",
            audioDuration: 1, sttLatency: 0.301, insertionOutcome: "inserted"
        )

        XCTAssertEqual(
            TranscriptMetadataFormatter.pipelineSegments(for: record),
            ["STT: Groq, 301 ms", "Total: —"]
        )
    }

    func testTranscriptMetadataLabelsCleanupAndTotalPipelineLatency() {
        let record = TranscriptRecord(
            rawText: "hello", finalText: "Hello.", sttProvider: .groq, sttModel: "whisper",
            audioDuration: 1, sttLatency: 0.301, pipelineLatency: 0.612,
            cleanup: .init(provider: .groq, model: "gpt-oss", latency: 0.184),
            insertionOutcome: "inserted"
        )

        XCTAssertEqual(
            TranscriptMetadataFormatter.pipelineSegments(for: record),
            ["STT: Groq, 301 ms", "Cleanup: Groq, 184 ms", "Total: 612 ms"]
        )
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

    func testHomeEstimatedMinutesSavedComparesSpeechWithFortyWPMTyping() {
        let words = Array(repeating: "word", count: 240).joined(separator: " ")
        let transcript = TranscriptRecord(
            rawText: words, finalText: words, sttProvider: .groq, sttModel: "whisper",
            audioDuration: 120, sttLatency: 0.1, insertionOutcome: "inserted"
        )
        var statistics = LifetimeStatistics()
        statistics.record(transcript)

        XCTAssertEqual(HomeDashboardAnalytics.estimatedMinutesSaved(from: statistics), 4)
    }

    func testHomeTranscriptSearchMatchesCurrentTextRawTextAndSourceApp() {
        let revised = TranscriptRevision(
            text: "Plan the September launch", origin: .manual, repairLatency: 0
        )
        let launch = TranscriptRecord(
            createdAt: Date(timeIntervalSince1970: 300),
            rawText: "Plan the August launch", finalText: "Plan the August launch",
            sttProvider: .groq, sttModel: "whisper", sourceBundleID: "com.apple.mail",
            audioDuration: 1, sttLatency: 0.1, insertionOutcome: "inserted",
            revisions: [revised], preferredRevisionID: revised.id
        )
        let notes = TranscriptRecord(
            createdAt: Date(timeIntervalSince1970: 200),
            rawText: "Capture café notes", finalText: "Capture café notes",
            sttProvider: .groq, sttModel: "whisper", sourceBundleID: "com.apple.Notes",
            audioDuration: 1, sttLatency: 0.1, insertionOutcome: "inserted"
        )

        XCTAssertEqual(
            HomeDashboardAnalytics.transcripts(matching: "september", in: [notes, launch]).map(\.id),
            [launch.id]
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

    func testHomeTopApplicationRanksKnownBundleIdentifiersByUsage() {
        let transcripts = [
            TranscriptRecord(
                rawText: "One", finalText: "One", sttProvider: .groq, sttModel: "whisper",
                sourceBundleID: "com.apple.mail", audioDuration: 1, sttLatency: 0.1,
                insertionOutcome: "inserted"
            ),
            TranscriptRecord(
                rawText: "Two", finalText: "Two", sttProvider: .groq, sttModel: "whisper",
                sourceBundleID: "com.apple.Notes", audioDuration: 1, sttLatency: 0.1,
                insertionOutcome: "inserted"
            ),
            TranscriptRecord(
                rawText: "Three", finalText: "Three", sttProvider: .groq, sttModel: "whisper",
                sourceBundleID: "com.apple.mail", audioDuration: 1, sttLatency: 0.1,
                insertionOutcome: "inserted"
            ),
            TranscriptRecord(
                rawText: "No app", finalText: "No app", sttProvider: .groq, sttModel: "whisper",
                audioDuration: 1, sttLatency: 0.1, insertionOutcome: "clipboard"
            ),
        ]

        XCTAssertEqual(
            HomeDashboardAnalytics.topApplication(in: transcripts),
            HomeApplicationUsage(bundleIdentifier: "com.apple.mail", transcriptCount: 2)
        )
    }

    func testUsageCurrencyFormattingUsesStableFractionPrecision() {
        XCTAssertEqual(
            UsageDisplayFormatter.currency(Decimal(string: "0.0119277777777777793024")!, complete: true),
            "$0.0119"
        )
        XCTAssertEqual(UsageDisplayFormatter.currency(2, complete: true), "$2.00")
        XCTAssertEqual(UsageDisplayFormatter.currency(1, complete: false), "Partially available")
    }

    private func assertColor(
        _ color: NSColor?,
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let color = color?.usingColorSpace(.deviceRGB) else {
            return XCTFail("Expected an RGB color", file: file, line: line)
        }
        XCTAssertEqual(color.redComponent, red / 255, accuracy: 0.04, file: file, line: line)
        XCTAssertEqual(color.greenComponent, green / 255, accuracy: 0.04, file: file, line: line)
        XCTAssertEqual(color.blueComponent, blue / 255, accuracy: 0.04, file: file, line: line)
        XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.001, file: file, line: line)
    }
}
