import DictatorCore
import SwiftUI

struct UsageView: View {
    @ObservedObject var model: AppModel
    @State private var days = 7

    private var summary: UsageSummary {
        UsageAnalytics.summarize(
            model.data.transcripts,
            since: Calendar.current.date(byAdding: .day, value: -days, to: Date())!,
            rates: model.pricingSnapshot?.rates ?? PricingCatalog.fallbackRates
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Usage").font(.dictatorDisplay(30))
                        Text("Local consumption and estimated USD costs. STT and LLM usage are reported separately.").font(.dictatorBody(13)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Range", selection: $days) { Text("7 days").tag(7); Text("30 days").tag(30) }.pickerStyle(.segmented).frame(width: 180)
                }
                usageSection("Speech to text") {
                    metricGrid([
                        ("Dictations", "\(summary.dictations)"),
                        ("Audio", String(format: "%.1f min", summary.audioSeconds / 60)),
                        ("Words", "\(summary.words)"),
                        ("STT cost", currency(summary.sttCost, complete: summary.pricedSTTCount == summary.dictations)),
                        ("Median request", latency(summary.sttMedianLatency)),
                        ("STT tokens", "N/A — billed by audio duration")
                    ])
                    providerBreakdown(stt: true)
                }
                usageSection("LLM cleanup") {
                    metricGrid([
                        ("Cleanup requests", "\(summary.cleanupRequests)"),
                        ("Input tokens", "\(summary.inputTokens)"),
                        ("Output tokens", "\(summary.outputTokens)"),
                        ("LLM cost", currency(summary.llmCost, complete: summary.pricedLLMCount == summary.cleanupRequests)),
                        ("Median cleanup", latency(summary.cleanupMedianLatency))
                    ])
                    providerBreakdown(stt: false)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.pricingSnapshot.map { "models.dev catalog refreshed \($0.fetchedAt.dictatorTimestamp)" } ?? "Using dated fallback prices")
                        Text("Estimates exclude free tiers, credits, discounts, taxes, and account contracts.")
                        if let error = model.pricingError { Text(error).foregroundStyle(.orange) }
                    }.font(.dictatorBody(11)).foregroundStyle(.secondary)
                    Spacer()
                    Button(model.pricingRefreshInProgress ? "Refreshing…" : "Refresh pricing") { Task { await model.refreshPricing(force: true) } }
                        .disabled(model.pricingRefreshInProgress).dictatorButton(.secondary)
                }
            }.frame(maxWidth: DictatorDesign.contentWidth, alignment: .leading).padding(42)
        }.task { await model.refreshPricing() }
    }

    private func usageSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) { Text(title).font(.dictatorDisplay(20)); content() }
            .padding(18).background(DictatorDesign.control, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(DictatorDesign.border))
    }

    private func metricGrid(_ values: [(String, String)]) -> some View {
        LazyVGrid(columns: [.init(.adaptive(minimum: 145))], alignment: .leading, spacing: 16) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                VStack(alignment: .leading, spacing: 4) { Text(value.1).font(.dictatorDisplay(17)).lineLimit(2); Text(value.0).font(.dictatorBody(10)).foregroundStyle(.secondary) }
            }
        }
    }

    private func providerBreakdown(stt: Bool) -> some View {
        let rows = breakdownRows(stt: stt)
        return VStack(alignment: .leading, spacing: 6) {
            Text("PROVIDER / MODEL").font(.dictatorUtility(9)).foregroundStyle(.secondary)
            ForEach(rows) { row in
                HStack {
                    Text(row.name).font(.dictatorBody(11, weight: .medium)); Spacer()
                    Text(row.detail).font(.dictatorUtility(9)).foregroundStyle(.secondary)
                }.padding(.vertical, 3)
            }
            if rows.isEmpty { Text("No usage in this period").font(.dictatorBody(11)).foregroundStyle(.secondary) }
        }.padding(.top, 8)
    }

    private struct Breakdown: Identifiable { let name: String; let detail: String; var id: String { name } }

    private func breakdownRows(stt: Bool) -> [Breakdown] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let records = model.data.transcripts.filter { $0.createdAt >= cutoff }
        if stt {
            return Dictionary(grouping: records) { "\($0.sttProvider.rawValue) · \($0.sttModel)" }.map { key, values in
                let seconds = values.reduce(0) { $0 + $1.audioDuration }
                let cost = values.compactMap { PricingCatalog.estimatedSTTCost(provider: $0.sttProvider, model: $0.sttModel, audioSeconds: $0.audioDuration) }.reduce(0, +)
                let median = values.map(\.sttLatency).sorted()[values.count / 2]
                return Breakdown(name: key, detail: "\(values.count) req · \(String(format: "%.1f", seconds / 60)) min · \(latency(median)) · $\(NSDecimalNumber(decimal: cost).stringValue)")
            }.sorted { $0.name < $1.name }
        }
        struct Event { let key: String; let usage: LLMUsage; let latency: TimeInterval; let provider: ProviderKind; let model: String }
        var events: [Event] = records.compactMap { record in
            guard let provider = record.llmProvider, let model = record.llmModel, let usage = record.llmUsage, let latency = record.cleanupLatency else { return nil }
            return Event(key: "\(provider.rawValue) · \(model)", usage: usage, latency: latency, provider: provider, model: model)
        }
        events += records.flatMap(\.revisions).compactMap { revision in
            guard revision.origin == .cleanup, let provider = revision.llmProvider, let model = revision.llmModel, let usage = revision.llmUsage else { return nil }
            return Event(key: "\(provider.rawValue) · \(model)", usage: usage, latency: revision.repairLatency, provider: provider, model: model)
        }
        return Dictionary(grouping: events, by: \.key).map { key, values in
            let input = values.reduce(0) { $0 + $1.usage.inputTokens }, output = values.reduce(0) { $0 + $1.usage.outputTokens }
            let costs = values.compactMap { PricingCatalog.estimatedLLMCost(provider: $0.provider, model: $0.model, usage: $0.usage, rates: model.pricingSnapshot?.rates ?? PricingCatalog.fallbackRates) }
            let latencies = values.map(\.latency).sorted(); let median = latencies[latencies.count / 2]
            let costText = costs.count == values.count ? "$\(NSDecimalNumber(decimal: costs.reduce(0, +)).stringValue)" : "cost N/A"
            return Breakdown(name: key, detail: "\(values.count) req · \(input)/\(output) tokens · \(latency(median)) · \(costText)")
        }.sorted { $0.name < $1.name }
    }

    private func latency(_ value: TimeInterval?) -> String { value.map { String(format: "%.0f ms", $0 * 1_000) } ?? "—" }
    private func currency(_ value: Decimal, complete: Bool) -> String {
        guard complete else { return "Partially available" }
        return "$" + NSDecimalNumber(decimal: value).stringValue
    }
}
