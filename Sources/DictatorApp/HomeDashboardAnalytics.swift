import DictatorCore
import Foundation

struct HomeActivityPoint: Equatable, Identifiable {
    let date: Date
    let speechMinutes: Double

    var id: Date { date }
}

enum HomeDashboardAnalytics {
    static func activity(
        in transcripts: [TranscriptRecord],
        endingAt now: Date = Date(),
        calendar: Calendar = .current
    ) -> [HomeActivityPoint] {
        let end = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -6, to: end) else { return [] }
        let dates = (0..<7).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: start)
        }
        var secondsByDate = Dictionary(uniqueKeysWithValues: dates.map { ($0, 0.0) })

        for transcript in transcripts {
            let date = calendar.startOfDay(for: transcript.createdAt)
            guard secondsByDate[date] != nil else { continue }
            secondsByDate[date, default: 0] += transcript.audioDuration
        }

        return dates.map { date in
            HomeActivityPoint(date: date, speechMinutes: secondsByDate[date, default: 0] / 60)
        }
    }

    static func formattedSpokenTime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours) hr \(minutes) min" : "\(hours) hr"
        }
        if minutes > 0 { return "\(minutes) min" }
        return "\(total) sec"
    }

    static func transcripts(
        matching query: String,
        in transcripts: [TranscriptRecord]
    ) -> [TranscriptRecord] {
        let ordered = transcripts.sorted { $0.createdAt > $1.createdAt }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return ordered }

        return ordered.filter { transcript in
            [transcript.finalText, transcript.rawText, transcript.sourceBundleID ?? ""]
                .contains { candidate in
                    candidate.range(
                        of: query,
                        options: [.caseInsensitive, .diacriticInsensitive]
                    ) != nil
                }
        }
    }
}
