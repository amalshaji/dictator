import DictatorCore
import Foundation
import SwiftUI

struct HomeView: View {
    @ObservedObject var model: AppModel
    @State private var selectedTranscript: TranscriptRecord?
    @State private var transcriptQuery = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                dashboardOverview
                Divider().padding(.vertical, 28)
                transcriptSectionHeader
                if model.data.transcripts.isEmpty {
                    emptyState
                } else if displayedTranscripts.isEmpty {
                    searchEmptyState
                } else {
                    transcriptList
                }
            }
            .frame(maxWidth: DictatorDesign.contentWidth, alignment: .leading)
            .padding(.horizontal, 42)
            .padding(.vertical, 36)
        }
        .scrollIndicators(.hidden)
        .sheet(item: $selectedTranscript) { record in TranscriptDetailView(model: model, transcriptID: record.id) }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 9) {
                Text("Ready when you are").font(.dictatorDisplay(32)).foregroundStyle(DictatorDesign.ink)
                Text(model.accessMode == .leastPrivileges
                    ? model.accessMode.recordingInstruction
                    : (model.dictateActivationMode == .hold
                        ? "Hold \(model.dictateShortcut.displayName), speak naturally, then release."
                        : "Press \(model.dictateShortcut.displayName), speak naturally, then press it again."))
                    .font(.dictatorBody(15)).foregroundStyle(DictatorDesign.inkSecondary)
            }
            Spacer()
            HStack(spacing: 8) {
                Circle().fill(DictatorDesign.orchid).frame(width: 8, height: 8)
                Text(providerDisplayName(model.selectedSTT)).font(.dictatorUtility(11))
            }
            .padding(.horizontal, 12).frame(height: 30)
            .background(DictatorDesign.fog, in: Capsule())
        }
    }

    private var dashboardOverview: some View {
        HomeDashboardOverview(
            activity: HomeDashboardAnalytics.activity(in: model.data.transcripts),
            words: wordCount(in: weeklyTranscripts),
            averageWPM: averageWPM(in: weeklyTranscripts),
            averageLatency: averageLatency(in: weeklyTranscripts),
            lifetimeStatistics: model.data.lifetimeStatistics,
            topApplication: HomeDashboardAnalytics.topApplication(in: model.data.transcripts)
        )
        .padding(.top, 26)
    }

    private var transcriptList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(displayedTranscripts) { record in
                Button { selectedTranscript = record } label: { HomeTranscriptRow(record: record) }.buttonStyle(.plain)
                Divider()
            }
        }
        .padding(.top, 12)
    }

    private var transcriptSectionHeader: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text(isSearching ? "Transcripts" : "Recent transcripts")
                    .font(.dictatorDisplay(20))
                if isSearching {
                    Text("\(displayedTranscripts.count) \(displayedTranscripts.count == 1 ? "match" : "matches")")
                        .font(.dictatorBody(10.5))
                        .foregroundStyle(DictatorDesign.muted)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DictatorDesign.muted)
                    .accessibilityHidden(true)
                TextField("Search transcripts", text: $transcriptQuery)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .font(.dictatorBody(12.5))
                if !transcriptQuery.isEmpty {
                    Button {
                        transcriptQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(DictatorDesign.muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear transcript search")
                }
            }
            .padding(.horizontal, 10)
            .frame(width: 238, height: 34)
            .background(DictatorDesign.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(searchFocused ? DictatorDesign.focus : DictatorDesign.border, lineWidth: searchFocused ? 1.5 : 1)
            }
            .animation(.easeOut(duration: 0.12), value: searchFocused)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your first transcript will appear here.").font(.dictatorBody(15, weight: .medium))
            Text("Dictator keeps text locally for 30 days and never stores recordings after transcription. Apple processing stays on-device; cloud processing sends audio only to your selected provider.")
                .font(.dictatorBody(13)).foregroundStyle(DictatorDesign.inkSecondary)
        }
        .padding(.vertical, 42)
    }

    private var searchEmptyState: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("No matching transcripts")
                .font(.dictatorBody(14, weight: .medium))
            Text("Try another word or phrase. Your local transcript history covers the last 30 days.")
                .font(.dictatorBody(12.5))
                .foregroundStyle(DictatorDesign.muted)
        }
        .padding(.vertical, 32)
        .accessibilityElement(children: .combine)
    }

    private var isSearching: Bool {
        !transcriptQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var displayedTranscripts: [TranscriptRecord] {
        let matches = HomeDashboardAnalytics.transcripts(
            matching: transcriptQuery,
            in: model.data.transcripts
        )
        return isSearching ? matches : Array(matches.prefix(5))
    }

    private var weeklyTranscripts: [TranscriptRecord] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        return model.data.transcripts.filter { $0.createdAt >= cutoff }
    }

    private func wordCount(in transcripts: [TranscriptRecord]) -> Int {
        transcripts.reduce(0) { $0 + $1.finalText.split(whereSeparator: \.isWhitespace).count }
    }

    private func averageWPM(in transcripts: [TranscriptRecord]) -> Int? {
        let totalSeconds = transcripts.reduce(0) { $0 + $1.audioDuration }
        guard totalSeconds > 0 else { return nil }
        return Int(Double(wordCount(in: transcripts)) / totalSeconds * 60)
    }

    private func averageLatency(in transcripts: [TranscriptRecord]) -> TimeInterval? {
        let latencies = transcripts.compactMap(\.pipelineLatency)
        guard !latencies.isEmpty else { return nil }
        return latencies.reduce(0, +) / Double(latencies.count)
    }

    private func providerDisplayName(_ kind: ProviderKind) -> String {
        ProviderRegistry.sttMetadata(includeAppleSpeech: true).first { $0.kind == kind }?.displayName ?? kind.rawValue
    }
}
