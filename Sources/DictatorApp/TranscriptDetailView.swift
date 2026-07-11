import DictatorCore
import SwiftUI

struct TranscriptDetailView: View {
    @ObservedObject var model: AppModel
    let transcriptID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var editText = ""
    @State private var editing = false
    @State private var teaching = false
    @State private var incorrect = ""
    @State private var correct = ""
    @State private var teachError: String?
    @State private var confirmReprocess = false
    @State private var preview: TranscriptRevision?
    @State private var working = false

    private var record: TranscriptRecord? { model.data.transcripts.first { $0.id == transcriptID } }

    var body: some View {
        Group {
            if let record {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack { Text("Transcript details").font(.dictatorDisplay(26)); Spacer(); Button("Done") { dismiss() }.dictatorButton(.ghost) }
                        actionBar(record)
                        textSection("Current text", record.currentText)
                        textSection("Original processed text", record.finalText)
                        textSection("Raw transcription", record.rawText)
                        latencySection(record)
                        metadataSection(record)
                        if !record.revisions.isEmpty {
                            Text("Revisions").font(.dictatorDisplay(18))
                            ForEach(record.revisions.reversed()) { revision in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(revision.text).textSelection(.enabled)
                                    Text(revisionMetadata(revision))
                                        .font(.dictatorUtility(10)).foregroundStyle(.secondary)
                                }.padding(12).background(DictatorDesign.control, in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }.padding(28)
                }
            } else { Text("Transcript is no longer available.").padding(30) }
        }
        .frame(width: 680, height: 720)
        .sheet(isPresented: $editing) { manualEditor }
        .sheet(isPresented: $teaching) { teachEditor }
        .sheet(item: $preview) { revision in previewView(revision) }
        .confirmationDialog(
            "Reprocess raw transcript?",
            isPresented: $confirmReprocess,
            titleVisibility: .visible
        ) {
            Button("Reprocess") { Task { await createPreview() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            if model.cleanupEnabled {
                Text("This sends stored text to \(model.selectedLLM.rawValue) using \(model.configuredModel(for: .cleanup, provider: model.selectedLLM) ?? "the default model") and may incur cost.")
            } else { Text("This reapplies current vocabulary and snippets locally.") }
        }
    }

    private func actionBar(_ record: TranscriptRecord) -> some View {
        HStack {
            Button("Copy raw") { model.copyTranscriptText(record.rawText) }.dictatorButton(.secondary)
            Button("Copy current") { model.copyTranscriptText(record.currentText) }.dictatorButton(.secondary)
            Button("Paste current") { Task { await model.pasteTranscriptText(record.currentText) } }.dictatorButton(.secondary)
            Button("Edit") { editText = record.currentText; editing = true }.dictatorButton(.secondary)
            Button("Reprocess") { confirmReprocess = true }.disabled(working).dictatorButton()
            Button("Teach Dictator") { teaching = true }.dictatorButton(.ghost)
        }
    }

    private func textSection(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(title.uppercased()).font(.dictatorUtility(9)).foregroundStyle(.secondary); Text(text).font(.dictatorBody(13)).textSelection(.enabled) }
    }

    private func latencySection(_ record: TranscriptRecord) -> some View {
        let total = record.pipelineLatency
        let overhead = total.map { max(0, $0 - record.sttLatency - (record.cleanup?.latency ?? 0)) }
        return VStack(alignment: .leading, spacing: 7) {
            Text("LATENCY").font(.dictatorUtility(9)).foregroundStyle(.secondary)
            HStack { value("Total pipeline", total.map(latency) ?? "—"); value("STT request", latency(record.sttLatency)); value("LLM cleanup", record.cleanup.map { latency($0.latency) } ?? "—"); value("Other overhead", overhead.map(latency) ?? "—") }
        }
    }

    private func metadataSection(_ record: TranscriptRecord) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("PROVENANCE").font(.dictatorUtility(9)).foregroundStyle(.secondary)
            Text("STT: \(record.sttProvider.rawValue) · \(record.sttModel)").font(.dictatorBody(11))
            if let cleanup = record.cleanup { Text("Cleanup: \(cleanup.provider.rawValue) · \(cleanup.model)").font(.dictatorBody(11)) }
            Text("Insertion: \(record.insertionOutcome)" + (record.sourceBundleID.map { " · \($0)" } ?? "")).font(.dictatorBody(11))
            if let cleanup = record.cleanup, let usage = cleanup.usage {
                Text("Tokens: \(tokenText(usage))").font(.dictatorBody(11))
                Text("LLM cost: \(costText(provider: cleanup.provider, model: cleanup.model, usage: usage))").font(.dictatorBody(11))
            }
        }
    }

    private var manualEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit transcript").font(.dictatorDisplay(22)); TextEditor(text: $editText).frame(minHeight: 180).dictatorEditor()
            HStack { Spacer(); Button("Cancel") { editing = false }.dictatorButton(.ghost); Button("Save revision") {
                let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                model.appendRevision(.init(text: trimmed, origin: .manual, repairLatency: 0), to: transcriptID); editing = false
            }.dictatorButton() }
        }.padding(24).frame(width: 520)
    }

    private var teachEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Teach Dictator").font(.dictatorDisplay(22))
            TextField("Incorrect phrase", text: $incorrect).textFieldStyle(DictatorTextFieldStyle())
            TextField("Correct phrase", text: $correct).textFieldStyle(DictatorTextFieldStyle())
            Text("Nothing is learned automatically. Saving creates or updates a vocabulary rule.").font(.dictatorBody(11)).foregroundStyle(.secondary)
            if let teachError { Text(teachError).font(.dictatorBody(11, weight: .medium)).foregroundStyle(.red) }
            HStack { Spacer(); Button("Cancel") { teaching = false; teachError = nil }.dictatorButton(.ghost); Button("Save rule") {
                if model.teachDictator(incorrect: incorrect, correct: correct) { teaching = false; incorrect = ""; correct = ""; teachError = nil }
                else { teachError = model.lastError ?? "Could not save this correction." }
            }.dictatorButton() }
        }.padding(24).frame(width: 480)
    }

    private func previewView(_ revision: TranscriptRevision) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Reprocessed preview").font(.dictatorDisplay(22))
            Text(revision.text).font(.dictatorBody(13)).textSelection(.enabled).padding(12).background(DictatorDesign.control, in: RoundedRectangle(cornerRadius: 10))
            Text("\(revision.origin.label) · \(latency(revision.repairLatency))").font(.dictatorBody(11)).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Cancel") { preview = nil }.dictatorButton(.ghost); Button("Save revision") { model.appendRevision(revision, to: transcriptID); preview = nil }.dictatorButton() }
        }.padding(24).frame(width: 520)
    }

    private func createPreview() async {
        working = true; defer { working = false }
        do { preview = try await model.reprocessTranscript(transcriptID) }
        catch { model.lastError = error.localizedDescription }
    }

    private func revisionMetadata(_ revision: TranscriptRevision) -> String {
        var parts = [revision.origin.label, latency(revision.repairLatency), revision.createdAt.dictatorTimestamp]
        if case .cleanup(let cleanup) = revision.origin, let usage = cleanup.usage {
            parts.append(tokenText(usage))
            parts.append(costText(provider: cleanup.provider, model: cleanup.model, usage: usage))
        }
        return parts.joined(separator: " · ")
    }

    private func costText(provider: ProviderKind, model modelName: String, usage: LLMUsage) -> String {
        let rates = model.pricingSnapshot?.rates ?? PricingCatalog.fallbackRates
        guard let cost = PricingCatalog.estimatedLLMCost(provider: provider, model: modelName, usage: usage, rates: rates) else { return "unavailable" }
        return "$" + NSDecimalNumber(decimal: cost).stringValue + (usage.providerReportedCostUSD == nil ? " estimated" : " reported")
    }
    private func tokenText(_ usage: LLMUsage) -> String {
        guard let input = usage.inputTokens, let output = usage.outputTokens else { return "unavailable" }
        return "\(input) in / \(output) out"
    }

    private func value(_ label: String, _ text: String) -> some View { VStack(alignment: .leading, spacing: 3) { Text(text).font(.dictatorDisplay(15)); Text(label).font(.dictatorBody(9)).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading) }
    private func latency(_ value: TimeInterval) -> String { String(format: "%.0f ms", value * 1_000) }
}
