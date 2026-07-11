import Foundation

public struct UsageReport: Equatable, Sendable {
    public struct STTSummary: Equatable, Sendable {
        public var dictations = 0
        public var audioSeconds: TimeInterval = 0
        public var words = 0
        public var cost: Decimal = 0
        public var pricedRequests = 0
        public var medianLatency: TimeInterval?
    }

    public struct LLMSummary: Equatable, Sendable {
        public var requests = 0
        public var inputTokens = 0
        public var outputTokens = 0
        public var inputTokenSamples = 0
        public var outputTokenSamples = 0
        public var cost: Decimal = 0
        public var pricedRequests = 0
        public var medianLatency: TimeInterval?
    }

    public struct STTBreakdown: Identifiable, Equatable, Sendable {
        public let provider: ProviderKind
        public let model: String
        public let requests: Int
        public let audioSeconds: TimeInterval
        public let medianLatency: TimeInterval?
        public let cost: Decimal
        public let pricedRequests: Int
        public var id: String { "\(provider.rawValue)/\(model)" }
    }

    public struct LLMBreakdown: Identifiable, Equatable, Sendable {
        public let provider: ProviderKind
        public let model: String
        public let requests: Int
        public let inputTokens: Int
        public let outputTokens: Int
        public let inputTokenSamples: Int
        public let outputTokenSamples: Int
        public let medianLatency: TimeInterval?
        public let cost: Decimal
        public let pricedRequests: Int
        public var id: String { "\(provider.rawValue)/\(model)" }
    }

    public var stt = STTSummary()
    public var llm = LLMSummary()
    public var sttBreakdown: [STTBreakdown] = []
    public var llmBreakdown: [LLMBreakdown] = []

    public init() {}
}

public enum UsageAnalytics {
    public static func report(
        _ records: [TranscriptRecord],
        since cutoff: Date,
        rates: [String: ModelTokenRate]
    ) -> UsageReport {
        let sttRecords = records.filter { $0.createdAt >= cutoff }
        let llmEvents = cleanupEvents(in: records, since: cutoff)
        var report = UsageReport()

        report.stt.dictations = sttRecords.count
        report.stt.audioSeconds = sttRecords.reduce(0) { $0 + $1.audioDuration }
        report.stt.words = sttRecords.reduce(0) { $0 + $1.finalText.split(whereSeparator: \.isWhitespace).count }
        report.stt.medianLatency = median(sttRecords.map(\.sttLatency))
        for record in sttRecords {
            if let cost = PricingCatalog.estimatedSTTCost(provider: record.sttProvider, model: record.sttModel, audioSeconds: record.audioDuration) {
                report.stt.cost += cost
                report.stt.pricedRequests += 1
            }
        }

        for event in llmEvents {
            report.llm.requests += 1
            if let tokens = event.execution.usage?.inputTokens {
                report.llm.inputTokens += tokens
                report.llm.inputTokenSamples += 1
            }
            if let tokens = event.execution.usage?.outputTokens {
                report.llm.outputTokens += tokens
                report.llm.outputTokenSamples += 1
            }
            if let usage = event.execution.usage,
               let cost = PricingCatalog.estimatedLLMCost(
                   provider: event.execution.provider,
                   model: event.execution.model,
                   usage: usage,
                   rates: rates
               ) {
                report.llm.cost += cost
                report.llm.pricedRequests += 1
            }
        }
        report.llm.medianLatency = median(llmEvents.map { $0.execution.latency })
        report.sttBreakdown = sttBreakdowns(sttRecords)
        report.llmBreakdown = llmBreakdowns(llmEvents, rates: rates)
        return report
    }

    public static func median(_ values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    private struct CleanupEvent {
        let date: Date
        let execution: CleanupExecution
    }

    private static func cleanupEvents(in records: [TranscriptRecord], since cutoff: Date) -> [CleanupEvent] {
        var events = records.compactMap { record -> CleanupEvent? in
            guard record.createdAt >= cutoff, let cleanup = record.cleanup else { return nil }
            return CleanupEvent(date: record.createdAt, execution: cleanup)
        }
        events += records.flatMap(\.revisions).compactMap { revision in
            guard revision.createdAt >= cutoff, case .cleanup(let cleanup) = revision.origin else { return nil }
            return CleanupEvent(date: revision.createdAt, execution: cleanup)
        }
        return events
    }

    private static func sttBreakdowns(_ records: [TranscriptRecord]) -> [UsageReport.STTBreakdown] {
        Dictionary(grouping: records) { "\($0.sttProvider.rawValue)/\($0.sttModel)" }
            .map { _, values in
                let costs = values.compactMap {
                    PricingCatalog.estimatedSTTCost(provider: $0.sttProvider, model: $0.sttModel, audioSeconds: $0.audioDuration)
                }
                return .init(
                    provider: values[0].sttProvider,
                    model: values[0].sttModel,
                    requests: values.count,
                    audioSeconds: values.reduce(0) { $0 + $1.audioDuration },
                    medianLatency: median(values.map(\.sttLatency)),
                    cost: costs.reduce(0, +),
                    pricedRequests: costs.count
                )
            }
            .sorted { $0.id < $1.id }
    }

    private static func llmBreakdowns(
        _ events: [CleanupEvent],
        rates: [String: ModelTokenRate]
    ) -> [UsageReport.LLMBreakdown] {
        Dictionary(grouping: events) { "\($0.execution.provider.rawValue)/\($0.execution.model)" }
            .map { _, values in
                let executions = values.map(\.execution)
                let input = executions.compactMap { $0.usage?.inputTokens }
                let output = executions.compactMap { $0.usage?.outputTokens }
                let costs = executions.compactMap { execution in
                    execution.usage.flatMap {
                        PricingCatalog.estimatedLLMCost(provider: execution.provider, model: execution.model, usage: $0, rates: rates)
                    }
                }
                return .init(
                    provider: executions[0].provider,
                    model: executions[0].model,
                    requests: executions.count,
                    inputTokens: input.reduce(0, +),
                    outputTokens: output.reduce(0, +),
                    inputTokenSamples: input.count,
                    outputTokenSamples: output.count,
                    medianLatency: median(executions.map(\.latency)),
                    cost: costs.reduce(0, +),
                    pricedRequests: costs.count
                )
            }
            .sorted { $0.id < $1.id }
    }
}
