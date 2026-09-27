import DictatorCore
import Foundation
import SwiftUI

struct HomeTranscriptRow: View {
    let record: TranscriptRecord

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let bundleIdentifier = record.sourceBundleID {
                HomeApplicationIcon(identity: HomeApplicationIdentity(bundleIdentifier: bundleIdentifier), size: 30)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let bundleIdentifier = record.sourceBundleID {
                        Text(HomeApplicationIdentity(bundleIdentifier: bundleIdentifier).name)
                        Text("·")
                    }
                    Text(TranscriptRowFormatter.relativeTime(from: record.createdAt))
                }
                .font(.dictatorCaption(weight: .medium))
                .foregroundStyle(DictatorDesign.textSecondary)
                .lineLimit(1)

                Text(TranscriptRowFormatter.firstLine(of: record.finalText))
                    .font(.dictatorBodyLarge)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 13)
    }
}

enum TranscriptRowFormatter {
    nonisolated(unsafe) private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func firstLine(of text: String) -> String {
        text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? text
    }

    static func relativeTime(from date: Date, relativeTo now: Date = Date()) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: now)
    }
}
