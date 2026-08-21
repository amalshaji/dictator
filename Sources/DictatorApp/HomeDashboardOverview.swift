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
    let topApplication: HomeApplicationUsage?

    var body: some View {
        VStack(spacing: 14) {
            HomeActivityChart(
                activity: activity,
                words: words,
                averageWPM: averageWPM,
                averageLatency: averageLatency
            )
            HStack(spacing: 14) {
                HomeTimeSavedCard(statistics: lifetimeStatistics)
                HomeTopApplicationCard(usage: topApplication)
            }
        }
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
                        .font(.dictatorDisplay(18))
                    Text("LAST 7 DAYS · \(totalSpeechMinutes, specifier: "%.1f") MIN SPOKEN")
                        .font(.dictatorUtility(9))
                        .foregroundStyle(DictatorDesign.muted)
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
                .foregroundStyle(DictatorDesign.signalInk)
                .cornerRadius(4)
            }
            .chartYScale(domain: 0...chartMaximum)
            .chartXAxis {
                AxisMarks(values: activity.map(\.date)) {
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                        .foregroundStyle(DictatorDesign.muted)
                    AxisTick().foregroundStyle(DictatorDesign.border)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) {
                    AxisGridLine().foregroundStyle(DictatorDesign.fog)
                    AxisValueLabel().foregroundStyle(DictatorDesign.muted)
                }
            }
            .frame(height: 126)
            .accessibilityLabel("Speech activity for the last seven days")
            .accessibilityValue("\(totalSpeechMinutes, specifier: "%.1f") minutes spoken")
        }
        .padding(18)
        .background(DictatorDesign.control, in: RoundedRectangle(cornerRadius: DictatorDesign.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DictatorDesign.cornerRadius, style: .continuous)
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
                .font(.dictatorDisplay(17))
                .monospacedDigit()
            Text(label)
                .font(.dictatorUtility(9))
                .foregroundStyle(DictatorDesign.muted)
        }
    }
}

private struct HomeTimeSavedCard: View {
    let statistics: LifetimeStatistics

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "clock.arrow.2.circlepath")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(DictatorDesign.signalInk)
                .frame(width: 38, height: 38)
                .background(DictatorDesign.orchid.opacity(0.58), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text("ALL TIME")
                    .font(.dictatorUtility(9))
                    .foregroundStyle(DictatorDesign.muted)
                Text(displayValue)
                    .font(.dictatorDisplay(22))
                    .monospacedDigit()
                Text("estimated typing time saved · 40 wpm baseline")
                    .font(.dictatorBody(10.5))
                    .foregroundStyle(DictatorDesign.muted)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
        .padding(16)
        .background(DictatorDesign.control, in: RoundedRectangle(cornerRadius: DictatorDesign.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DictatorDesign.cornerRadius, style: .continuous)
                .stroke(DictatorDesign.border.opacity(0.82))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Estimated typing time saved, \(displayValue), based on 40 words per minute")
    }

    private var displayValue: String {
        let minutes = HomeDashboardAnalytics.estimatedMinutesSaved(from: statistics)
        if minutes > 0, minutes < 1 { return "<1 min" }
        return "\(Int(minutes.rounded())) min"
    }
}

private struct HomeTopApplicationCard: View {
    let usage: HomeApplicationUsage?

    var body: some View {
        HStack(spacing: 14) {
            if let usage {
                let identity = HomeApplicationIdentity(bundleIdentifier: usage.bundleIdentifier)
                HomeApplicationIcon(identity: identity)
                VStack(alignment: .leading, spacing: 3) {
                    Text("TOP APP · 30 DAYS")
                        .font(.dictatorUtility(9))
                        .foregroundStyle(DictatorDesign.muted)
                    Text(identity.name)
                        .font(.dictatorDisplay(20))
                        .lineLimit(1)
                    Text("\(usage.transcriptCount) \(usage.transcriptCount == 1 ? "transcript" : "transcripts")")
                        .font(.dictatorBody(10.5))
                        .foregroundStyle(DictatorDesign.muted)
                }
            } else {
                HomeApplicationIcon(identity: nil)
                VStack(alignment: .leading, spacing: 3) {
                    Text("TOP APP · 30 DAYS")
                        .font(.dictatorUtility(9))
                        .foregroundStyle(DictatorDesign.muted)
                    Text("No app data yet")
                        .font(.dictatorDisplay(18))
                    Text("Apps appear after your first insertion")
                        .font(.dictatorBody(10.5))
                        .foregroundStyle(DictatorDesign.muted)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
        .padding(16)
        .background(DictatorDesign.control, in: RoundedRectangle(cornerRadius: DictatorDesign.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DictatorDesign.cornerRadius, style: .continuous)
                .stroke(DictatorDesign.border.opacity(0.82))
        }
        .accessibilityElement(children: .combine)
    }
}
