import Foundation

public struct TranscriptRepairService: Sendable {
    private let processor: TranscriptProcessor

    public init(processor: TranscriptProcessor = TranscriptProcessor()) {
        self.processor = processor
    }

    public func reprocess(
        record: TranscriptRecord,
        vocabulary: [VocabularyEntry],
        snippets: [SnippetEntry],
        cleanup: TranscriptCleanupConfiguration?
    ) async -> TranscriptRevision {
        let started = ContinuousClock.now
        let processed = await processor.process(
            rawText: record.rawText,
            vocabulary: vocabulary,
            snippets: snippets,
            cleanup: cleanup
        )
        let origin = processed.cleanupResult
            .map { TranscriptRevisionOrigin.cleanup(.init(result: $0)) }
            ?? .localProcessing
        return TranscriptRevision(
            text: processed.finalText,
            origin: origin,
            repairLatency: elapsedSeconds(since: started)
        )
    }

    private func elapsedSeconds(since instant: ContinuousClock.Instant) -> TimeInterval {
        let components = instant.duration(to: .now).components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
