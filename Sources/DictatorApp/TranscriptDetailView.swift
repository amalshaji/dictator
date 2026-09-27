import DictatorCore
import SwiftUI

struct TranscriptDetailView: View {
    let model: AppModel
    let transcriptID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var showingTeach = false

    private var record: TranscriptRecord? {
        model.data.transcripts.first { $0.id == transcriptID }
    }

    var body: some View {
        Group {
            if let record {
                VStack(alignment: .leading, spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            header(record)
                            Divider()
                            finalTextSection(record)
                            latencySection(record)
                            sourceTextSection(record)
                            technicalDetailsSection(record)
                        }
                        .padding(24)
                    }
                    Divider()
                    actionBar(record)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                }
            } else {
                Text("Transcript is no longer available.").padding(30)
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .onExitCommand { dismiss() }
        .sheet(isPresented: $showingTeach) {
            TranscriptTeachingEditor(model: model) { showingTeach = false }
        }
    }

    private func header(_ record: TranscriptRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Transcript details").font(.dictatorDisplay)
            Text(record.createdAt.dictatorTimestamp)
                .font(.dictatorCaption(weight: .medium))
                .foregroundStyle(DictatorDesign.textSecondary)
        }
    }

    private func actionBar(_ record: TranscriptRecord) -> some View {
        HStack(spacing: 8) {
            // Hidden so Esc always closes the sheet even if some other control
            // has claimed the Escape key equivalent elsewhere in the app.
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .hidden()
                .accessibilityHidden(true)

            Spacer()
            Button { model.copyTranscriptText(record.finalText) } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .dictatorButton(.secondary)
            .help("Copy the final transcript to the clipboard")

            if model.insertionMode == .insert {
                Button { Task { await model.pasteTranscriptText(record.finalText) } } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .dictatorButton(.secondary)
                .help("Paste the final transcript into the frontmost app")
            }

            Button("Teach Dictator…") { showingTeach = true }
                .dictatorButton(.secondary)
                .help("Add a vocabulary correction from this transcript")

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .dictatorButton()
                .help("Close this transcript")
        }
    }

    private func finalTextSection(_ record: TranscriptRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Final text").font(.dictatorBody(weight: .semibold)).foregroundStyle(DictatorDesign.textSecondary)
            Text(record.finalText)
                .font(.dictatorBodyLarge)
                .lineSpacing(3)
                .textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DictatorDesign.paper.opacity(0.72), in: RoundedRectangle(cornerRadius: DictatorDesign.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DictatorDesign.radiusCard, style: .continuous).stroke(DictatorDesign.border.opacity(0.8)))
    }

    private func latencySection(_ record: TranscriptRecord) -> some View {
        Text(latencySummary(record))
            .font(.dictatorBody(weight: .medium))
            .foregroundStyle(DictatorDesign.textSecondary)
    }

    private func latencySummary(_ record: TranscriptRecord) -> String {
        var parts = [record.pipelineLatency.map { "\(milliseconds($0)) ms total" } ?? "— total"]
        parts.append("STT \(milliseconds(record.sttLatency))")
        if let execution = record.llmExecution {
            parts.append("cleanup \(milliseconds(execution.latency))")
        }
        return parts.joined(separator: " · ")
    }

    private func sourceTextSection(_ record: TranscriptRecord) -> some View {
        DisclosureGroup {
            compactTextSection("Raw transcription", record.rawText)
                .padding(.top, 10)
        } label: {
            Label("Source text", systemImage: "text.alignleft")
                .font(.dictatorBody(weight: .semibold))
        }
        .disclosureGroupStyle(FullWidthDisclosureGroupStyle())
        .tint(DictatorDesign.textSecondary)
    }

    private func technicalDetailsSection(_ record: TranscriptRecord) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 5) {
                Text("STT: \(record.sttProvider.rawValue) · \(record.sttModel)")
                if let execution = record.llmExecution {
                    Text("Cleanup: \(execution.provider.rawValue) · \(execution.model)")
                }
                Text("Insertion: \(record.insertionOutcome)" + (record.sourceBundleID.map { " · \($0)" } ?? ""))
                if let execution = record.llmExecution, let usage = execution.usage {
                    Text("Tokens: \(tokenText(usage))")
                }
            }
            .font(.dictatorCaption)
            .foregroundStyle(DictatorDesign.textSecondary)
            .padding(.top, 10)
        } label: {
            Label("Technical details", systemImage: "info.circle")
                .font(.dictatorBody(weight: .semibold))
        }
        .disclosureGroupStyle(FullWidthDisclosureGroupStyle())
        .tint(DictatorDesign.textSecondary)
    }

    private func compactTextSection(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.dictatorBody(weight: .semibold)).foregroundStyle(DictatorDesign.textSecondary)
            Text(text).font(.dictatorBody).lineSpacing(2).textSelection(.enabled)
        }
    }

    private func tokenText(_ usage: LLMUsage) -> String {
        guard let input = usage.inputTokens, let output = usage.outputTokens else { return "unavailable" }
        return "\(input) in / \(output) out"
    }

    private func milliseconds(_ value: TimeInterval) -> String {
        String(format: "%.0f", value * 1_000)
    }
}

private struct FullWidthDisclosureGroupStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(DictatorDesign.glyphFont(size: 10, weight: .semibold))
                        .foregroundStyle(DictatorDesign.textSecondary)
                        .frame(width: 10)
                    configuration.label
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(configuration.isExpanded ? "Collapse section" : "Expand section")

            if configuration.isExpanded {
                configuration.content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct TranscriptTeachingEditor: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    let onSave: () -> Void
    @State private var incorrect = ""
    @State private var correct = ""
    @State private var validationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Teach Dictator").font(.dictatorDisplay)
            TextField("Incorrect phrase", text: $incorrect).textFieldStyle(DictatorTextFieldStyle())
            TextField("Correct phrase", text: $correct).textFieldStyle(DictatorTextFieldStyle())
            Text("Nothing is learned automatically. Saving creates or updates a vocabulary rule.")
                .font(.dictatorCaption).foregroundStyle(DictatorDesign.textSecondary)
            if let validationError {
                Text(validationError).font(.dictatorCaption(weight: .medium)).foregroundStyle(DictatorDesign.textError)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.dictatorButton(.ghost)
                Button("Save rule") {
                    do {
                        try model.teachDictator(incorrect: incorrect, correct: correct)
                        onSave()
                    } catch {
                        validationError = error.localizedDescription
                    }
                }
                .dictatorButton()
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
