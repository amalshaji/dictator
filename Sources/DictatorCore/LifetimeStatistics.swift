import Foundation

public struct LifetimeStatistics: Codable, Equatable, Sendable {
    public private(set) var dictations = 0
    public private(set) var words = 0
    public private(set) var audioSeconds: TimeInterval = 0
    public private(set) var pipelineLatencySeconds: TimeInterval = 0
    public private(set) var pipelineLatencySamples = 0

    public init() {}

    public var averageWPM: Int? {
        guard audioSeconds > 0 else { return nil }
        return Int(Double(words) / audioSeconds * 60)
    }

    public var averagePipelineLatency: TimeInterval? {
        guard pipelineLatencySamples > 0 else { return nil }
        return pipelineLatencySeconds / Double(pipelineLatencySamples)
    }

    public mutating func record(_ transcript: TranscriptRecord) {
        dictations += 1
        words += transcript.finalText.split(whereSeparator: \.isWhitespace).count
        audioSeconds += transcript.audioDuration
        if let pipelineLatency = transcript.pipelineLatency {
            pipelineLatencySeconds += pipelineLatency
            pipelineLatencySamples += 1
        }
    }
}
