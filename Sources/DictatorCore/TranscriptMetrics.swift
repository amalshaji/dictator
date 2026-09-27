import Foundation

public enum TranscriptMetrics {
    public static func wordCount(in text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    public static func wordsPerMinute(words: Int, seconds: TimeInterval) -> Int? {
        guard seconds > 0 else { return nil }
        return Int(Double(words) / seconds * 60)
    }

    public static func averageLatency(totalSeconds: TimeInterval, sampleCount: Int) -> TimeInterval? {
        guard sampleCount > 0 else { return nil }
        return totalSeconds / Double(sampleCount)
    }
}
