import XCTest
@testable import DictatorCore

final class TranscriptMetricsTests: XCTestCase {
    func testWordCountSplitsOnWhitespace() {
        XCTAssertEqual(TranscriptMetrics.wordCount(in: "One two three"), 3)
        XCTAssertEqual(TranscriptMetrics.wordCount(in: ""), 0)
    }

    func testWordsPerMinuteComputesRateOrNilWithoutAudio() {
        XCTAssertEqual(TranscriptMetrics.wordsPerMinute(words: 120, seconds: 120), 60)
        XCTAssertNil(TranscriptMetrics.wordsPerMinute(words: 10, seconds: 0))
    }
}
