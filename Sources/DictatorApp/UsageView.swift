import DictatorCore
import SwiftUI

enum UsageDisplayFormatter {
    static func currency(_ value: Decimal, complete: Bool) -> String {
        guard complete else { return "Partially available" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 4
        formatter.roundingMode = .halfUp
        return "$" + (formatter.string(from: NSDecimalNumber(decimal: value)) ?? "0.00")
    }
}

struct UsageView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var pricing: PricingStore
    @State private var days = 7

    init(model: AppModel) {
        self.model = model
        _pricing = ObservedObject(wrappedValue: model.pricing)
    }

    private var report: UsageReport {
        UsageAnalytics.report(
            model.data.transcripts,
            since: Calendar.current.date(byAdding: .day, value: -days, to: Date())!,
            rates: pricing.snapshot?.rates ?? PricingCatalog.fallbackRates
        )
    }

    var body: some View {
        ViewThatFits(in: .vertical) {
            pageContent.fixedSize(horizontal: false, vertical: true)
            ScrollView {
                pageContent
            }
        }
        .task { await pricing.refresh() }
    }

    private var pageContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            usageSection("Speech to text") {
                metricGrid([
                    ("Dictations", "\(report.stt.dictations)"),
                    ("Audio", String(format: "%.1f min", report.stt.audioSeconds / 60)),
                    ("Words", "\(report.stt.words)"),
                    ("STT cost", UsageDisplayFormatter.currency(report.stt.cost, complete: report.stt.pricedRequests == report.stt.dictations)),
                    ("Median request", latency(report.stt.medianLatency)),
                    ("STT tokens", "N/A — billed by audio duration")
                ])
                sttBreakdown
            }
            usageSection("LLM cleanup") {
                metricGrid([
                    ("Cleanup requests", "\(report.llm.requests)"),
                    ("Input tokens", tokenSummary(report.llm.inputTokens, samples: report.llm.inputTokenSamples)),
                    ("Output tokens", tokenSummary(report.llm.outputTokens, samples: report.llm.outputTokenSamples)),
                    ("LLM cost", UsageDisplayFormatter.currency(report.llm.cost, complete: report.llm.pricedRequests == report.llm.requests)),
                    ("Median cleanup", latency(report.llm.medianLatency))
                ])
                llmBreakdown
            }
            pricingFooter
        }
        .frame(maxWidth: DictatorDesign.contentWidth, alignment: .leading)
        .padding(.horizontal, 42)
        .padding(.vertical, 30)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 7) {
                Text("Usage").font(.dictatorDisplay(30))
                Text("Local consumption and estimated USD costs. STT and LLM usage are reported separately.")
                    .font(.dictatorBody(13)).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Range", selection: $days) {
                Text("7 days").tag(7)
                Text("30 days").tag(30)
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
        }
    }

    private var sttBreakdown: some View {
        breakdownContainer(isEmpty: report.sttBreakdown.isEmpty) {
            ForEach(report.sttBreakdown) { row in
                breakdownRow(
                    name: "\(sttProviderName(row.provider)) · \(row.model)",
                    detail: "\(row.requests) req · \(String(format: "%.1f", row.audioSeconds / 60)) min · \(latency(row.medianLatency)) · \(UsageDisplayFormatter.currency(row.cost, complete: row.pricedRequests == row.requests))"
                )
            }
        }
    }

    private func sttProviderName(_ provider: ProviderKind) -> String {
        ProviderRegistry.sttMetadata(includeAppleSpeech: true).first { $0.kind == provider }?.displayName ?? provider.rawValue
    }

    private var llmBreakdown: some View {
        breakdownContainer(isEmpty: report.llmBreakdown.isEmpty) {
            ForEach(report.llmBreakdown) { row in
                breakdownRow(
                    name: "\(row.provider.rawValue) · \(row.model)",
                    detail: "\(row.requests) req · \(breakdownTokens(row)) · \(latency(row.medianLatency)) · \(UsageDisplayFormatter.currency(row.cost, complete: row.pricedRequests == row.requests))"
                )
            }
        }
    }

    private var pricingFooter: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(pricing.snapshot.map { "models.dev catalog refreshed \($0.fetchedAt.dictatorTimestamp)" } ?? "Using dated fallback prices")
                Text("Estimates exclude free tiers, credits, discounts, taxes, and account contracts.")
                if let error = pricing.errorMessage { Text(error).foregroundStyle(.orange) }
            }
            .font(.dictatorBody(11))
            .foregroundStyle(.secondary)
            Spacer()
            Button(pricing.isRefreshing ? "Refreshing…" : "Refresh pricing") {
                Task { await pricing.refresh(force: true) }
            }
            .disabled(pricing.isRefreshing)
            .dictatorButton(.secondary)
        }
    }

    private func usageSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.dictatorDisplay(20))
            content()
        }
        .padding(16)
        .background(DictatorDesign.control, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DictatorDesign.border))
    }

    private func metricGrid(_ values: [(String, String)]) -> some View {
        LazyVGrid(columns: [.init(.adaptive(minimum: 145))], alignment: .leading, spacing: 12) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                VStack(alignment: .leading, spacing: 4) {
                    Text(value.1).font(.dictatorDisplay(17)).lineLimit(2)
                    Text(value.0).font(.dictatorBody(10)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func breakdownContainer<Content: View>(isEmpty: Bool, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PROVIDER / MODEL").font(.dictatorUtility(9)).foregroundStyle(.secondary)
            content()
            if isEmpty {
                Text("No usage in this period").font(.dictatorBody(11)).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 6)
    }

    private func breakdownRow(name: String, detail: String) -> some View {
        HStack {
            Text(name).font(.dictatorBody(11, weight: .medium))
            Spacer()
            Text(detail).font(.dictatorUtility(9)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func breakdownTokens(_ row: UsageReport.LLMBreakdown) -> String {
        guard row.inputTokenSamples == row.requests, row.outputTokenSamples == row.requests else { return "tokens N/A" }
        return "\(row.inputTokens)/\(row.outputTokens) tokens"
    }

    private func latency(_ value: TimeInterval?) -> String {
        value.map { String(format: "%.0f ms", $0 * 1_000) } ?? "—"
    }

    private func tokenSummary(_ value: Int, samples: Int) -> String {
        guard samples > 0 else { return "Unavailable" }
        return "\(value)" + (samples < report.llm.requests ? " (partial)" : "")
    }
}
