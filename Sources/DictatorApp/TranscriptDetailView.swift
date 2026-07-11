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
                    VStack(alignment: .leading, spacing: 16) {
                        header(record)
                        Divider()
                        actionBar(record)
                        if let processingError {
                            Label(processingError, systemImage: "exclamationmark.triangle.fill")
                                .font(.dictatorBody(11, weight: .medium))
                                .foregroundStyle(.red)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        }
                        currentTextSection(record)
                        latencySection(record)
                        revisionsSection(record)
                        sourceTextSection(record)
                        technicalDetailsSection(record)
                    }
                    .padding(24)
                }
            } else {
                Text("Transcript is no longer available.").padding(30)
            }
        }
        .frame(width: 620, height: 560)
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

    private func header(_ record: TranscriptRecord) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Transcript details").font(.dictatorDisplay(23))
                Text(record.createdAt.dictatorTimestamp)
                    .font(.dictatorUtility(10))
                    .foregroundStyle(DictatorDesign.muted)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .dictatorButton(.ghost)
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
        HStack(spacing: 8) {
            Button { model.copyTranscriptText(record.currentText) } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .dictatorButton(.secondary)

            Button { Task { await model.pasteTranscriptText(record.currentText) } } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
            }
            .dictatorButton(.secondary)

            Button { presentation = .edit(record.currentText) } label: {
                Label("Edit", systemImage: "pencil")
            }
            .dictatorButton(.secondary)

            Spacer(minLength: 4)

            Button { presentation = .confirmReprocess } label: {
                Label(working ? "Processing…" : "Reprocess", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(working)
            .dictatorButton()

            Menu {
                Button("Copy raw transcription") { model.copyTranscriptText(record.rawText) }
                Divider()
                Button("Teach Dictator…") { presentation = .teach }
            } label: {
                Text("More")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityHint("Shows raw-copy and vocabulary teaching actions")
        }
    }

    private func currentTextSection(_ record: TranscriptRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("CURRENT TEXT").font(.dictatorUtility(9)).foregroundStyle(DictatorDesign.muted)
                Spacer()
                if record.preferredRevisionID != nil {
                    Text("REVISION").font(.dictatorUtility(8)).foregroundStyle(DictatorDesign.focus)
                }
            }
            Text(record.currentText)
                .font(.dictatorBody(14))
                .lineSpacing(3)
                .textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DictatorDesign.paper.opacity(0.72), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(DictatorDesign.border.opacity(0.8)))
    }

    private func latencySection(_ record: TranscriptRecord) -> some View {
        let total = record.pipelineLatency
        let overhead = total.map { max(0, $0 - record.sttLatency - (record.cleanup?.latency ?? 0)) }
        return VStack(alignment: .leading, spacing: 8) {
            Text("LATENCY").font(.dictatorUtility(9)).foregroundStyle(DictatorDesign.muted)
            HStack(spacing: 0) {
                value("Total pipeline", total.map(latency) ?? "—")
                value("STT request", latency(record.sttLatency))
                value("LLM cleanup", record.cleanup.map { latency($0.latency) } ?? "—")
                value("Other overhead", overhead.map(latency) ?? "—")
            }
        }
        .padding(.horizontal, 2)
    }

    private func sourceTextSection(_ record: TranscriptRecord) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                if record.currentText != record.finalText {
                    compactTextSection("Original processed text", record.finalText)
                    Divider()
                }
                compactTextSection("Raw transcription", record.rawText)
            }
            .padding(.top, 10)
        } label: {
            Label("Source text", systemImage: "text.alignleft")
                .font(.dictatorBody(12, weight: .semibold))
        }
        .disclosureGroupStyle(FullWidthDisclosureGroupStyle())
        .tint(DictatorDesign.muted)
    }

    private func technicalDetailsSection(_ record: TranscriptRecord) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 5) {
                Text("STT: \(record.sttProvider.rawValue) · \(record.sttModel)")
                if let cleanup = record.cleanup {
                    Text("Cleanup: \(cleanup.provider.rawValue) · \(cleanup.model)")
                }
                Text("Insertion: \(record.insertionOutcome)" + (record.sourceBundleID.map { " · \($0)" } ?? ""))
                if let cleanup = record.cleanup, let usage = cleanup.usage {
                    Text("Tokens: \(tokenText(usage))")
                    Text("LLM cost: \(costText(execution: cleanup))")
                }
            }
            .font(.dictatorBody(11))
            .foregroundStyle(DictatorDesign.ink.opacity(0.72))
            .padding(.top, 10)
        } label: {
            Label("Technical details", systemImage: "info.circle")
                .font(.dictatorBody(12, weight: .semibold))
        }
        .disclosureGroupStyle(FullWidthDisclosureGroupStyle())
        .tint(DictatorDesign.muted)
    }

    private func compactTextSection(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(.dictatorUtility(8)).foregroundStyle(DictatorDesign.muted)
            Text(text).font(.dictatorBody(12)).lineSpacing(2).textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func revisionsSection(_ record: TranscriptRecord) -> some View {
        if !record.revisions.isEmpty {
            Text("Revisions").font(.dictatorDisplay(16))
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
            Text(text).font(.dictatorDisplay(14)).monospacedDigit()
            Text(label).font(.dictatorBody(9)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func latency(_ value: TimeInterval) -> String {
        String(format: "%.0f ms", value * 1_000)
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
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DictatorDesign.muted)
                        .frame(width: 10)
                    configuration.label
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if configuration.isExpanded {
                configuration.content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
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
