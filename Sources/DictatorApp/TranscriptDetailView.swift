import DictatorCore
import SwiftUI

struct TranscriptDetailView: View {
    @ObservedObject var model: AppModel
    let transcriptID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var presentation: Presentation?
    @State private var processingError: String?
    @State private var working = false

    private enum Presentation: Identifiable {
        case edit(String)
        case teach
        case confirmReprocess
        case preview(TranscriptRevision)

        var id: String {
            switch self {
            case .edit: "edit"
            case .teach: "teach"
            case .confirmReprocess: "confirmReprocess"
            case .preview(let revision): "preview-\(revision.id)"
            }
        }
    }

    private var record: TranscriptRecord? {
        model.data.transcripts.first { $0.id == transcriptID }
    }

    var body: some View {
        Group {
            if let record {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            Text("Transcript details").font(.dictatorDisplay(26))
                            Spacer()
                            Button("Done") { dismiss() }.dictatorButton(.ghost)
                        }
                        actionBar(record)
                        if let processingError {
                            Text(processingError).font(.dictatorBody(11, weight: .medium)).foregroundStyle(.red)
                        }
                        textSection("Current text", record.currentText)
                        textSection("Original processed text", record.finalText)
                        textSection("Raw transcription", record.rawText)
                        latencySection(record)
                        metadataSection(record)
                        revisionsSection(record)
                    }
                    .padding(28)
                }
            } else {
                Text("Transcript is no longer available.").padding(30)
            }
        }
        .frame(width: 680, height: 720)
        .sheet(item: sheetPresentation) { sheetContent($0) }
        .confirmationDialog(
            "Reprocess raw transcript?",
            isPresented: confirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Reprocess") { Task { await createPreview() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            if model.cleanupEnabled {
                Text("This sends stored text to \(model.selectedLLM.rawValue) using \(model.configuredModel(for: .cleanup, provider: model.selectedLLM) ?? "the default model") and may incur cost.")
            } else {
                Text("This reapplies current vocabulary and snippets locally.")
            }
        }
    }

    private var sheetPresentation: Binding<Presentation?> {
        Binding(
            get: {
                guard let presentation else { return nil }
                if case .confirmReprocess = presentation { return nil }
                return presentation
            },
            set: { if $0 == nil { presentation = nil } }
        )
    }

    private var confirmationPresented: Binding<Bool> {
        Binding(
            get: { if case .confirmReprocess = presentation { true } else { false } },
            set: { if !$0 { presentation = nil } }
        )
    }

    @ViewBuilder
    private func sheetContent(_ presentation: Presentation) -> some View {
        switch presentation {
        case .edit(let text):
            TranscriptManualEditor(initialText: text) { text in
                model.appendRevision(.init(text: text, origin: .manual, repairLatency: 0), to: transcriptID)
                self.presentation = nil
            }
        case .teach:
            TranscriptTeachingEditor(model: model) { self.presentation = nil }
        case .preview(let revision):
            previewView(revision)
        case .confirmReprocess:
            EmptyView()
        }
    }

    private func actionBar(_ record: TranscriptRecord) -> some View {
        HStack {
            Button("Copy raw") { model.copyTranscriptText(record.rawText) }.dictatorButton(.secondary)
            Button("Copy current") { model.copyTranscriptText(record.currentText) }.dictatorButton(.secondary)
            Button("Paste current") { Task { await model.pasteTranscriptText(record.currentText) } }.dictatorButton(.secondary)
            Button("Edit") { presentation = .edit(record.currentText) }.dictatorButton(.secondary)
            Button("Reprocess") { presentation = .confirmReprocess }.disabled(working).dictatorButton()
            Button("Teach Dictator") { presentation = .teach }.dictatorButton(.ghost)
        }
    }

    private func textSection(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.dictatorUtility(9)).foregroundStyle(.secondary)
            Text(text).font(.dictatorBody(13)).textSelection(.enabled)
        }
    }

    private func latencySection(_ record: TranscriptRecord) -> some View {
        let total = record.pipelineLatency
        let overhead = total.map { max(0, $0 - record.sttLatency - (record.cleanup?.latency ?? 0)) }
        return VStack(alignment: .leading, spacing: 7) {
            Text("LATENCY").font(.dictatorUtility(9)).foregroundStyle(.secondary)
            HStack {
                value("Total pipeline", total.map(latency) ?? "—")
                value("STT request", latency(record.sttLatency))
                value("LLM cleanup", record.cleanup.map { latency($0.latency) } ?? "—")
                value("Other overhead", overhead.map(latency) ?? "—")
            }
        }
    }

    private func metadataSection(_ record: TranscriptRecord) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("PROVENANCE").font(.dictatorUtility(9)).foregroundStyle(.secondary)
            Text("STT: \(record.sttProvider.rawValue) · \(record.sttModel)").font(.dictatorBody(11))
            if let cleanup = record.cleanup {
                Text("Cleanup: \(cleanup.provider.rawValue) · \(cleanup.model)").font(.dictatorBody(11))
            }
            Text("Insertion: \(record.insertionOutcome)" + (record.sourceBundleID.map { " · \($0)" } ?? ""))
                .font(.dictatorBody(11))
            if let cleanup = record.cleanup, let usage = cleanup.usage {
                Text("Tokens: \(tokenText(usage))").font(.dictatorBody(11))
                Text("LLM cost: \(costText(execution: cleanup))").font(.dictatorBody(11))
            }
        }
    }

    @ViewBuilder
    private func revisionsSection(_ record: TranscriptRecord) -> some View {
        if !record.revisions.isEmpty {
            Text("Revisions").font(.dictatorDisplay(18))
            ForEach(record.revisions.reversed()) { revision in
                VStack(alignment: .leading, spacing: 5) {
                    Text(revision.text).textSelection(.enabled)
                    Text(revisionMetadata(revision)).font(.dictatorUtility(10)).foregroundStyle(.secondary)
                }
                .padding(12)
                .background(DictatorDesign.control, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func previewView(_ revision: TranscriptRevision) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Reprocessed preview").font(.dictatorDisplay(22))
            Text(revision.text).font(.dictatorBody(13)).textSelection(.enabled)
                .padding(12).background(DictatorDesign.control, in: RoundedRectangle(cornerRadius: 10))
            Text("\(revision.origin.label) · \(latency(revision.repairLatency))")
                .font(.dictatorBody(11)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { presentation = nil }.dictatorButton(.ghost)
                Button("Save revision") {
                    model.appendRevision(revision, to: transcriptID)
                    presentation = nil
                }
                .dictatorButton()
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func createPreview() async {
        working = true
        processingError = nil
        defer { working = false }
        do {
            presentation = .preview(try await model.reprocessTranscript(transcriptID))
        } catch {
            presentation = nil
            processingError = error.localizedDescription
        }
    }

    private func revisionMetadata(_ revision: TranscriptRevision) -> String {
        var parts = [revision.origin.label, latency(revision.repairLatency), revision.createdAt.dictatorTimestamp]
        if case .cleanup(let cleanup) = revision.origin, let usage = cleanup.usage {
            parts.append(tokenText(usage))
            parts.append(costText(execution: cleanup))
        }
        return parts.joined(separator: " · ")
    }

    private func costText(execution: CleanupExecution) -> String {
        guard let usage = execution.usage,
              let cost = PricingCatalog.estimatedLLMCost(
                  provider: execution.provider,
                  model: execution.model,
                  usage: usage,
                  rates: model.pricing.snapshot?.rates ?? PricingCatalog.fallbackRates
              )
        else { return "unavailable" }
        return "$" + NSDecimalNumber(decimal: cost).stringValue
            + (usage.providerReportedCostUSD == nil ? " estimated" : " reported")
    }

    private func tokenText(_ usage: LLMUsage) -> String {
        guard let input = usage.inputTokens, let output = usage.outputTokens else { return "unavailable" }
        return "\(input) in / \(output) out"
    }

    private func value(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(text).font(.dictatorDisplay(15))
            Text(label).font(.dictatorBody(9)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func latency(_ value: TimeInterval) -> String {
        String(format: "%.0f ms", value * 1_000)
    }
}

private struct TranscriptManualEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    let onSave: (String) -> Void

    init(initialText: String, onSave: @escaping (String) -> Void) {
        _text = State(initialValue: initialText)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit transcript").font(.dictatorDisplay(22))
            TextEditor(text: $text).frame(minHeight: 180).dictatorEditor()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.dictatorButton(.ghost)
                Button("Save revision") {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    onSave(trimmed)
                }
                .dictatorButton()
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

private struct TranscriptTeachingEditor: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let onSave: () -> Void
    @State private var incorrect = ""
    @State private var correct = ""
    @State private var validationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Teach Dictator").font(.dictatorDisplay(22))
            TextField("Incorrect phrase", text: $incorrect).textFieldStyle(DictatorTextFieldStyle())
            TextField("Correct phrase", text: $correct).textFieldStyle(DictatorTextFieldStyle())
            Text("Nothing is learned automatically. Saving creates or updates a vocabulary rule.")
                .font(.dictatorBody(11)).foregroundStyle(.secondary)
            if let validationError {
                Text(validationError).font(.dictatorBody(11, weight: .medium)).foregroundStyle(.red)
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
