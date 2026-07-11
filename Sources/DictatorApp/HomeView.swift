import DictatorCore
import SwiftUI

struct HomeView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                metrics
                Divider().padding(.vertical, 28)
                Text("Recent transcripts").font(.dictatorDisplay(20))
                if model.data.transcripts.isEmpty { emptyState } else { transcriptList }
            }
            .frame(maxWidth: DictatorDesign.contentWidth, alignment: .leading)
            .padding(.horizontal, 42)
            .padding(.vertical, 36)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 9) {
                Text("Ready when you are").font(.dictatorDisplay(32)).foregroundStyle(DictatorDesign.ink)
                Text("Hold \(model.dictateShortcut.displayName), speak naturally, then release.")
                    .font(.dictatorBody(15)).foregroundStyle(DictatorDesign.ink.opacity(0.58))
            }
            Spacer()
            HStack(spacing: 8) {
                Circle().fill(DictatorDesign.orchid).frame(width: 8, height: 8)
                Text(model.selectedSTT.rawValue).font(.dictatorUtility(11))
            }
            .padding(.horizontal, 12).frame(height: 30)
            .background(DictatorDesign.fog, in: Capsule())
        }
    }

    private var metrics: some View {
        HStack(spacing: 0) {
            metric(value: "\(wordsThisWeek)", label: "words this week")
            metric(value: averageWPM.map(String.init) ?? "—", label: "average wpm")
            metric(value: averageLatency.map { String(format: "%.0f ms", $0 * 1_000) } ?? "—", label: "STT latency")
        }
        .padding(.top, 34)
    }

    private func metric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.dictatorDisplay(22)).monospacedDigit()
            Text(label).font(.dictatorBody(11, weight: .medium)).foregroundStyle(DictatorDesign.ink.opacity(0.48))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var transcriptList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(model.data.transcripts) { record in
                TranscriptRow(record: record)
                Divider()
            }
        }
        .padding(.top, 12)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your first transcript will appear here.").font(.dictatorBody(15, weight: .medium))
            Text("Dictator keeps text locally for 30 days and does not store recordings after sending them to your selected provider.")
                .font(.dictatorBody(13)).foregroundStyle(DictatorDesign.ink.opacity(0.52))
        }
        .padding(.vertical, 42)
    }

    private var wordsThisWeek: Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        return model.data.transcripts.filter { $0.createdAt >= cutoff }.reduce(0) { $0 + $1.finalText.split(whereSeparator: \.isWhitespace).count }
    }

    private var averageWPM: Int? {
        let totalSeconds = model.data.transcripts.reduce(0) { $0 + $1.audioDuration }
        guard totalSeconds > 0 else { return nil }
        let words = model.data.transcripts.reduce(0) { $0 + $1.finalText.split(whereSeparator: \.isWhitespace).count }
        return Int(Double(words) / totalSeconds * 60)
    }

    private var averageLatency: Double? {
        guard !model.data.transcripts.isEmpty else { return nil }
        return model.data.transcripts.reduce(0) { $0 + $1.sttLatency } / Double(model.data.transcripts.count)
    }
}

enum TranscriptMetadataFormatter {
    static func pipelineSegments(for record: TranscriptRecord) -> [String] {
        var segments = ["STT: \(sttDisplayName(for: record.sttProvider)), \(milliseconds(record.sttLatency))"]
        guard let cleanupProvider = record.llmProvider else { return segments }

        let providerName = cleanupDisplayName(for: cleanupProvider)
        guard let cleanupLatency = record.cleanupLatency else {
            segments.append("Cleanup: \(providerName)")
            return segments
        }

        segments.append("Cleanup: \(providerName), \(milliseconds(cleanupLatency))")
        segments.append("Total: \(milliseconds(record.sttLatency + cleanupLatency))")
        return segments
    }

    private static func sttDisplayName(for kind: ProviderKind) -> String {
        ProviderRegistry.sttMetadata.first { $0.kind == kind }?.displayName ?? kind.rawValue
    }

    private static func cleanupDisplayName(for kind: ProviderKind) -> String {
        CleanupProviderRegistry.metadata.first { $0.kind == kind }?.displayName ?? kind.rawValue
    }

    private static func milliseconds(_ latency: TimeInterval) -> String {
        String(format: "%.0f ms", latency * 1_000)
    }
}

private struct TranscriptRow: View {
    let record: TranscriptRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(record.finalText).font(.dictatorBody(14)).lineLimit(3).textSelection(.enabled)
            HStack(spacing: 10) {
                Text(record.createdAt.dictatorTimestamp)
                ForEach(TranscriptMetadataFormatter.pipelineSegments(for: record), id: \.self) { segment in
                    Text(segment)
                }
            }
            .font(.dictatorUtility(10)).foregroundStyle(DictatorDesign.ink.opacity(0.42))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 13)
    }
}
