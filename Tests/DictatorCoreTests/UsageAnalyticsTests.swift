import XCTest
@testable import DictatorCore

final class UsageAnalyticsTests: XCTestCase {
    func testScreenAwareExecutionCountsAsLLMUsage() {
        let execution = LLMExecution(
            purpose: .screenAware,
            provider: .groq,
            model: "meta-llama/llama-4-scout-17b-16e-instruct",
            latency: 0.4,
            usage: .init(inputTokens: 120, outputTokens: 18)
        )
        let record = TranscriptRecord(
            rawText: "Reply to this email",
            finalText: "Tuesday works for me.",
            sttProvider: .groq,
            sttModel: "whisper-large-v3-turbo",
            audioDuration: 2,
            sttLatency: 0.2,
            llmExecution: execution,
            insertionOutcome: "typed"
        )

        let report = UsageAnalytics.report([record], since: .distantPast, rates: PricingCatalog.fallbackRates)

        XCTAssertEqual(report.llm.requests, 1)
        XCTAssertEqual(report.llm.inputTokens, 120)
        XCTAssertEqual(report.llm.outputTokens, 18)
    }

    func testMissingTokensKeepRequestAndMakeCostUnavailable() {
        let cleanup = CleanupExecution(provider: .groq, model: "openai/gpt-oss-20b", latency: 0.2, usage: .init())
        let record = TranscriptRecord(rawText: "raw", finalText: "final", sttProvider: .groq, sttModel: "whisper-large-v3-turbo", audioDuration: 1, sttLatency: 0.1, cleanup: cleanup, insertionOutcome: "typed")
        let report = UsageAnalytics.report([record], since: .distantPast, rates: PricingCatalog.fallbackRates)
        XCTAssertEqual(report.llm.requests, 1)
        XCTAssertEqual(report.llm.pricedRequests, 0)
        XCTAssertEqual(report.llm.inputTokenSamples, 0)
        XCTAssertEqual(report.llm.outputTokenSamples, 0)
    }

    func testMedianAveragesEvenMiddlePairAndHandlesOddCounts() {
        XCTAssertEqual(UsageAnalytics.median([4, 1, 3, 2]), 2.5)
        XCTAssertEqual(UsageAnalytics.median([9, 1, 4]), 4)
        XCTAssertNil(UsageAnalytics.median([]))
    }

    func testReportKeepsSTTAndLLMSeparateAndBuildsProviderRows() {
        let cleanup = CleanupExecution(provider: .groq, model: "openai/gpt-oss-20b", latency: 0.2, usage: .init(inputTokens: 100, outputTokens: 20))
        let record = TranscriptRecord(rawText: "hello", finalText: "Hello", sttProvider: .groq, sttModel: "whisper-large-v3-turbo", audioDuration: 60, sttLatency: 0.3, cleanup: cleanup, insertionOutcome: "typed")
        let report = UsageAnalytics.report([record], since: .distantPast, rates: PricingCatalog.fallbackRates)
        XCTAssertEqual(report.stt.dictations, 1)
        XCTAssertEqual(report.llm.requests, 1)
        XCTAssertEqual(report.llm.inputTokens, 100)
        XCTAssertGreaterThan(report.stt.cost, 0)
        XCTAssertGreaterThan(report.llm.cost, 0)
        XCTAssertEqual(report.sttBreakdown.first?.requests, 1)
        XCTAssertEqual(report.llmBreakdown.first?.inputTokens, 100)
    }

    func testRecentRepairCountsAsLLMUsageWithoutRecountingOldSTT() {
        let now = Date()
        let cleanup = CleanupExecution(provider: .groq, model: "openai/gpt-oss-20b", latency: 0.1, usage: .init(inputTokens: 10, outputTokens: 3))
        let revision = TranscriptRevision(createdAt: now, text: "Repaired", origin: .cleanup(cleanup), repairLatency: 0.3)
        let record = TranscriptRecord(createdAt: now.addingTimeInterval(-40 * 86_400), rawText: "raw", finalText: "original", sttProvider: .groq, sttModel: "whisper-large-v3-turbo", audioDuration: 60, sttLatency: 0.2, insertionOutcome: "typed", revisions: [revision])
        let report = UsageAnalytics.report([record], since: now.addingTimeInterval(-7 * 86_400), rates: PricingCatalog.fallbackRates)
        XCTAssertEqual(report.stt.dictations, 0)
        XCTAssertEqual(report.stt.audioSeconds, 0)
        XCTAssertEqual(report.llm.requests, 1)
        XCTAssertEqual(report.llm.inputTokens, 10)
        XCTAssertEqual(report.llm.outputTokens, 3)
    }
}
