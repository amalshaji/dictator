import Foundation

public struct LifetimeStatistics: Codable, Equatable, Sendable {
    public private(set) var dictations = 0
    public private(set) var words = 0
    public private(set) var audioSeconds: TimeInterval = 0
    public private(set) var pipelineLatencySeconds: TimeInterval = 0
    public private(set) var pipelineLatencySamples = 0

    public init() {}

    public var averageWPM: Int? {
        TranscriptMetrics.wordsPerMinute(words: words, seconds: audioSeconds)
    }

    public var averagePipelineLatency: TimeInterval? {
        TranscriptMetrics.averageLatency(totalSeconds: pipelineLatencySeconds, sampleCount: pipelineLatencySamples)
    }

    public mutating func record(_ transcript: TranscriptRecord) {
        dictations += 1
        words += TranscriptMetrics.wordCount(in: transcript.finalText)
        audioSeconds += transcript.audioDuration
        if let pipelineLatency = transcript.pipelineLatency {
            pipelineLatencySeconds += pipelineLatency
            pipelineLatencySamples += 1
        }
    }
}
