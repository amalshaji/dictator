import DictatorCore
import Foundation
import SwiftUI

struct HomeTranscriptRow: View {
    let record: TranscriptRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(record.currentText)
                .font(.dictatorBody(14))
                .lineLimit(3)
                .textSelection(.enabled)
            HStack(spacing: 10) {
                if let bundleIdentifier = record.sourceBundleID {
                    let identity = HomeApplicationIdentity(bundleIdentifier: bundleIdentifier)
                    HStack(spacing: 5) {
                        HomeApplicationIcon(identity: identity, size: 16)
                        Text(identity.name)
                            .lineLimit(1)
                    }
                }
                Text(record.createdAt.dictatorTimestamp)
                ForEach(TranscriptMetadataFormatter.pipelineSegments(for: record), id: \.self) { segment in
                    Text(segment)
                }
            }
            .font(.dictatorUtility(10))
            .foregroundStyle(DictatorDesign.ink.opacity(0.42))
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 13)
    }
}

enum TranscriptMetadataFormatter {
    static func pipelineSegments(for record: TranscriptRecord) -> [String] {
        var segments = ["STT: \(sttDisplayName(for: record.sttProvider)), \(milliseconds(record.sttLatency))"]
        if let execution = record.llmExecution {
            let providerName = llmDisplayName(for: execution.provider)
            let label = execution.purpose == .cleanup ? "Cleanup" : "Screen aware"
            segments.append("\(label): \(providerName), \(milliseconds(execution.latency))")
        }
        segments.append(record.pipelineLatency.map { "Total: \(milliseconds($0))" } ?? "Total: —")
        return segments
    }

    private static func sttDisplayName(for kind: ProviderKind) -> String {
        ProviderRegistry.sttMetadata(includeAppleSpeech: true).first { $0.kind == kind }?.displayName ?? kind.rawValue
    }

    private static func llmDisplayName(for kind: ProviderKind) -> String {
        CleanupProviderRegistry.metadata.first { $0.kind == kind }?.displayName ?? kind.rawValue
    }

    private static func milliseconds(_ latency: TimeInterval) -> String {
        String(format: "%.0f ms", latency * 1_000)
    }
}
