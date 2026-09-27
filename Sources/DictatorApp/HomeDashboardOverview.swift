import Charts
import DictatorCore
import Foundation
import SwiftUI

struct HomeDashboardOverview: View {
    let activity: [HomeActivityPoint]
    let words: Int
    let averageWPM: Int?
    let averageLatency: TimeInterval?
    let lifetimeStatistics: LifetimeStatistics

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HomeActivityChart(
                activity: activity,
                words: words,
                averageWPM: averageWPM,
                averageLatency: averageLatency
            )
            Text(lifetimeSummary)
                .font(.dictatorCaption)
                .foregroundStyle(DictatorDesign.textSecondary)
                .padding(.horizontal, 4)
        }
    }

    private var lifetimeSummary: String {
        let dictations = lifetimeStatistics.dictations
        let spoken = HomeDashboardAnalytics.formattedSpokenTime(lifetimeStatistics.audioSeconds)
        let words = lifetimeStatistics.words
        return "\(dictations.formatted()) \(dictations == 1 ? "dictation" : "dictations") · \(spoken) spoken · \(words.formatted()) words all time"
    }
}

private struct HomeActivityChart: View {
    let activity: [HomeActivityPoint]
    let words: Int
    let averageWPM: Int?
    let averageLatency: TimeInterval?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Speech activity")
                        .font(.dictatorTitle)
                    Text("Last 7 days · \(totalSpeechMinutes, specifier: "%.1f") min spoken")
                        .font(.dictatorCaption(weight: .semibold))
                        .foregroundStyle(DictatorDesign.textSecondary)
                }
                Spacer(minLength: 20)
                HStack(spacing: 22) {
                    chartMetric(value: "\(words)", label: "words")
                    chartMetric(value: averageWPM.map(String.init) ?? "—", label: "avg wpm")
                    chartMetric(
                        value: averageLatency.map { String(format: "%.0f", $0 * 1_000) } ?? "—",
                        label: "latency ms"
                    )
                }
            }

            Chart(activity) { point in
                BarMark(
                    x: .value("Day", point.date, unit: .day),
                    y: .value("Speech minutes", point.speechMinutes)
                )
                .foregroundStyle(DictatorDesign.accentForeground)
                .cornerRadius(4)
            }
            .chartYScale(domain: 0...chartMaximum)
            .chartXAxis {
                AxisMarks(values: activity.map(\.date)) {
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                        .foregroundStyle(DictatorDesign.textSecondary)
                    AxisTick().foregroundStyle(DictatorDesign.border)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) {
                    AxisGridLine().foregroundStyle(DictatorDesign.fog)
                    AxisValueLabel().foregroundStyle(DictatorDesign.textSecondary)
                }
            }
            .frame(height: 126)
            .accessibilityLabel("Speech activity for the last seven days")
            .accessibilityValue("\(totalSpeechMinutes, specifier: "%.1f") minutes spoken")
        }
        .padding(18)
        .background(DictatorDesign.control, in: RoundedRectangle(cornerRadius: DictatorDesign.radiusHero, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DictatorDesign.radiusHero, style: .continuous)
                .stroke(DictatorDesign.border.opacity(0.82))
        }
    }

    private var totalSpeechMinutes: Double {
        activity.reduce(0) { $0 + $1.speechMinutes }
    }

    private var chartMaximum: Double {
        max(1, (activity.map(\.speechMinutes).max() ?? 0) * 1.15)
    }

    private func chartMetric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.dictatorTitle)
                .monospacedDigit()
            Text(label)
                .font(.dictatorCaption(weight: .medium))
                .foregroundStyle(DictatorDesign.textSecondary)
        }
    }
}
