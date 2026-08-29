import DictatorCore
import Foundation

struct HomeActivityPoint: Equatable, Identifiable {
    let date: Date
    let speechMinutes: Double

    var id: Date { date }
}

struct HomeApplicationUsage: Equatable {
    let bundleIdentifier: String
    let transcriptCount: Int
}

enum HomeDashboardAnalytics {
    static let assumedTypingWordsPerMinute = 40.0

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

    static func estimatedMinutesSaved(from statistics: LifetimeStatistics) -> Double {
        let typingMinutes = Double(statistics.words) / assumedTypingWordsPerMinute
        let speechMinutes = statistics.audioSeconds / 60
        return max(0, typingMinutes - speechMinutes)
    }

    static func transcripts(
        matching query: String,
        in transcripts: [TranscriptRecord]
    ) -> [TranscriptRecord] {
        let ordered = transcripts.sorted { $0.createdAt > $1.createdAt }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return ordered }

        return ordered.filter { transcript in
            [transcript.currentText, transcript.rawText, transcript.sourceBundleID ?? ""]
                .contains { candidate in
                    candidate.range(
                        of: query,
                        options: [.caseInsensitive, .diacriticInsensitive]
                    ) != nil
                }
        }
    }

    static func topApplication(in transcripts: [TranscriptRecord]) -> HomeApplicationUsage? {
        var usage: [String: (count: Int, lastUsedAt: Date)] = [:]

        for transcript in transcripts {
            guard let bundleIdentifier = transcript.sourceBundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !bundleIdentifier.isEmpty else { continue }
            let current = usage[bundleIdentifier]
            usage[bundleIdentifier] = (
                count: (current?.count ?? 0) + 1,
                lastUsedAt: max(current?.lastUsedAt ?? .distantPast, transcript.createdAt)
            )
        }

        guard let top = usage.max(by: { lhs, rhs in
            if lhs.value.count != rhs.value.count { return lhs.value.count < rhs.value.count }
            if lhs.value.lastUsedAt != rhs.value.lastUsedAt { return lhs.value.lastUsedAt < rhs.value.lastUsedAt }
            return lhs.key > rhs.key
        }) else { return nil }

        return HomeApplicationUsage(
            bundleIdentifier: top.key,
            transcriptCount: top.value.count
        )
    }
}
