import DictatorCore
import Foundation
import SwiftUI

struct HomeView: View {
    let model: AppModel
    @State private var selectedTranscript: TranscriptRecord?
    @State private var transcriptQuery = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        let transcripts = model.data.transcripts
        let isSearching = !transcriptQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let matches = HomeDashboardAnalytics.transcripts(matching: transcriptQuery, in: transcripts)
        let displayedTranscripts = isSearching ? matches : Array(matches.prefix(5))
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        let weeklyTranscripts = transcripts.filter { $0.createdAt >= cutoff }

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                dashboardOverview(transcripts: transcripts, weeklyTranscripts: weeklyTranscripts)
                Divider().padding(.vertical, 28)
                transcriptSectionHeader(isSearching: isSearching, matchCount: displayedTranscripts.count)
                if transcripts.isEmpty {
                    emptyState
                } else if displayedTranscripts.isEmpty {
                    searchEmptyState
                } else {
                    transcriptList(displayedTranscripts)
                }
            }
            .frame(maxWidth: DictatorDesign.contentWidth, alignment: .leading)
            .padding(.horizontal, 42)
            .padding(.vertical, 36)
            .background(searchFocusShortcut)
        }
        .scrollIndicators(.hidden)
        .sheet(item: $selectedTranscript) { record in TranscriptDetailView(model: model, transcriptID: record.id) }
    }

    private var searchFocusShortcut: some View {
        Button("") { searchFocused = true }
            .buttonStyle(.plain)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
            .keyboardShortcut("f", modifiers: .command)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 22) {
            DictateControl(model: model)
            VStack(alignment: .leading, spacing: 5) {
                Text(HomeHeaderPresentation.title(for: model.phase))
                    .font(.dictatorDisplay).foregroundStyle(DictatorDesign.ink)
                Text(instructionText)
                    .font(.dictatorBodyLarge).foregroundStyle(DictatorDesign.textSecondary)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Circle().fill(DictatorDesign.orchid).frame(width: 8, height: 8)
                Text(model.selectedSTT.displayName)
                    .font(.dictatorCaption(weight: .medium))
                    .foregroundStyle(DictatorDesign.textSecondary)
            }
            .padding(.horizontal, 12).frame(height: 30)
            .background(DictatorDesign.fog, in: Capsule())
        }
    }

    private var instructionText: String {
        if model.accessMode == .leastPrivileges {
            return "Press Dictate or use the menu bar; transcripts are copied to the clipboard."
        }
        if model.insertionMode == .insert {
            let action = model.dictateActivationMode == .toggle ? "press" : "hold"
            return "Dictate here copies the transcript; \(action) \(model.dictateShortcut.displayName) to insert into another app."
        }
        return "\(model.dictateInstruction)."
    }

    private func dashboardOverview(transcripts: [TranscriptRecord], weeklyTranscripts: [TranscriptRecord]) -> some View {
        let words = weeklyTranscripts.reduce(0) { $0 + TranscriptMetrics.wordCount(in: $1.finalText) }
        let audioSeconds = weeklyTranscripts.reduce(0) { $0 + $1.audioDuration }
        let latencies = weeklyTranscripts.compactMap(\.pipelineLatency)
        return HomeDashboardOverview(
            activity: HomeDashboardAnalytics.activity(in: transcripts),
            words: words,
            averageWPM: TranscriptMetrics.wordsPerMinute(words: words, seconds: audioSeconds),
            averageLatency: TranscriptMetrics.averageLatency(totalSeconds: latencies.reduce(0, +), sampleCount: latencies.count),
            lifetimeStatistics: model.data.lifetimeStatistics
        )
        .padding(.top, 26)
    }

    private func transcriptList(_ transcripts: [TranscriptRecord]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(transcripts) { record in
                Button { selectedTranscript = record } label: { HomeTranscriptRow(record: record) }
                    .buttonStyle(PressableRowStyle())
                Divider()
            }
        }
        .padding(.top, 12)
    }

    private func transcriptSectionHeader(isSearching: Bool, matchCount: Int) -> some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text(isSearching ? "Transcripts" : "Recent transcripts")
                    .font(.dictatorTitle)
                if isSearching {
                    Text("\(matchCount) \(matchCount == 1 ? "match" : "matches")")
                        .font(.dictatorCaption)
                        .foregroundStyle(DictatorDesign.textSecondary)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(DictatorDesign.glyphFont(size: 11, weight: .medium))
                    .foregroundStyle(DictatorDesign.textSecondary)
                    .accessibilityHidden(true)
                TextField("Search transcripts", text: $transcriptQuery)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .font(.dictatorBody)
                if !transcriptQuery.isEmpty {
                    Button {
                        transcriptQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(DictatorDesign.glyphFont(size: 11, weight: .regular))
                            .foregroundStyle(DictatorDesign.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear transcript search")
                    .accessibilityLabel("Clear transcript search")
                }
            }
            .padding(.horizontal, 10)
            .frame(minWidth: 180, maxWidth: 320)
            .frame(height: 34)
            .background(DictatorDesign.control, in: RoundedRectangle(cornerRadius: DictatorDesign.radiusControl, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DictatorDesign.radiusControl, style: .continuous)
                    .stroke(searchFocused ? DictatorDesign.focus : DictatorDesign.border, lineWidth: searchFocused ? 1.5 : 1)
            }
            .animation(.easeOut(duration: 0.12), value: searchFocused)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your first transcript will appear here.").font(.dictatorBodyLarge(weight: .medium))
            Text("Dictator keeps text locally for 30 days and never stores recordings after transcription. Apple processing stays on-device; cloud processing sends audio only to your selected provider.")
                .font(.dictatorBody).foregroundStyle(DictatorDesign.textSecondary)
        }
        .padding(.vertical, 42)
    }

    private var searchEmptyState: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("No matching transcripts")
                .font(.dictatorBodyLarge(weight: .medium))
            Text("Try another word or phrase. Your local transcript history covers the last 30 days.")
                .font(.dictatorBody)
                .foregroundStyle(DictatorDesign.textSecondary)
        }
        .padding(.vertical, 32)
        .accessibilityElement(children: .combine)
    }
}

/// The primary "Dictate" control: mic/Dictate while idle, stop/Stop while
/// listening, and a spinner while transcribing. Wired to the same model
/// calls as the menu-bar recording control, so it works in least-privilege
/// mode too.
private struct DictateControl: View {
    let model: AppModel

    var body: some View {
        Button {
            Task {
                switch model.phase {
                // Clicking Home activates Dictator's own window, so the Home
                // button always delivers via the clipboard: a captured system-wide
                // insertion target would otherwise be Dictator itself.
                case .idle: await model.startDictation(forceClipboardDelivery: true)
                case .listening: await model.stopDictation()
                case .processing: break
                }
            }
        } label: {
            HStack(spacing: 9) {
                switch model.phase {
                case .idle:
                    Image(systemName: "mic.fill")
                    Text("Dictate")
                case .listening:
                    Image(systemName: "stop.fill")
                    Text("Stop")
                case .processing:
                    ProgressView().controlSize(.small)
                    Text("Transcribing…")
                }
            }
        }
        .buttonStyle(DictateButtonStyle(phase: model.phase))
        .disabled(model.phase == .processing)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        switch model.phase {
        case .idle: "Dictate"
        case .listening: "Stop dictation"
        case .processing: "Transcribing"
        }
    }
}

enum HomeHeaderPresentation {
    static func title(for phase: DictationPhase) -> String {
        switch phase {
        case .idle: "Ready"
        case .listening: "Listening…"
        case .processing: "Transcribing…"
        }
    }
}
