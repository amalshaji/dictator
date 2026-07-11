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
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let records = model.data.transcripts.filter { $0.createdAt >= cutoff }
        let keys = Set(records.compactMap { record -> String? in
            if stt { return "\(record.sttProvider.rawValue) · \(record.sttModel)" }
            guard let provider = record.llmProvider, let model = record.llmModel else { return nil }; return "\(provider.rawValue) · \(model)"
        }).sorted()
        return VStack(alignment: .leading, spacing: 6) {
            Text("PROVIDER / MODEL").font(.dictatorUtility(9)).foregroundStyle(.secondary)
            ForEach(keys, id: \.self) { key in Text(key).font(.dictatorBody(11, weight: .medium)) }
            if keys.isEmpty { Text("No usage in this period").font(.dictatorBody(11)).foregroundStyle(.secondary) }
        }.padding(.top, 8)
    }

    private func latency(_ value: TimeInterval?) -> String { value.map { String(format: "%.0f ms", $0 * 1_000) } ?? "—" }
    private func currency(_ value: Decimal, complete: Bool) -> String {
        guard complete else { return "Partially available" }
        return "$" + NSDecimalNumber(decimal: value).stringValue
    }
}
