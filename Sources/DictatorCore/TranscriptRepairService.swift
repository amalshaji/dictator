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
    ) async throws -> TranscriptRevision {
        let started = ContinuousClock.now
        let processed = await processor.process(
            rawText: record.rawText,
            vocabulary: vocabulary,
            snippets: snippets,
            cleanup: cleanup
        )
        let text: String
        let origin: TranscriptRevisionOrigin
        switch processed {
        case .raw(let processedText), .fallback(let processedText, _):
            text = processedText
            origin = .localProcessing
        case .cleaned(let result):
            text = result.text
            origin = .cleanup(.init(result: result))
        case .failed(let reason):
            throw ProviderError.invalidConfiguration(reason)
        }
        return TranscriptRevision(
            text: text,
            origin: origin,
            repairLatency: elapsedSeconds(since: started)
        )
    }

    private func elapsedSeconds(since instant: ContinuousClock.Instant) -> TimeInterval {
        let components = instant.duration(to: .now).components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
