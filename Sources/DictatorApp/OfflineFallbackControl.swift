import SwiftUI

struct OfflineFallbackControl: View {
    @ObservedObject var model: AppModel
    let selectedAsPrimary: Bool
    let description: String?
    var prominent = false

    @State private var setupRequested = false
    @State private var errorMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let description {
                Text(description)
                    .font(.dictatorBody(12))
                    .foregroundStyle(.secondary)
            }

            if selectedAsPrimary {
                Label("Apple On-Device is your primary provider", systemImage: "checkmark.circle.fill")
                    .font(.dictatorBody(12, weight: .medium))
                    .foregroundStyle(.green)
            } else if model.offlineFallbackEnabled && model.appleSpeech.state.readiness.isReady {
                HStack(spacing: 8) {
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .font(.dictatorBody(12, weight: .medium))
                        .foregroundStyle(.green)
                    disableButton
                }
            } else {
                if model.offlineFallbackEnabled {
                    Label("The selected model needs to be downloaded again", systemImage: "exclamationmark.triangle.fill")
                        .font(.dictatorBody(11, weight: .medium))
                        .foregroundStyle(.orange)
                }
                HStack(spacing: 8) {
                    setupButton
                    if model.offlineFallbackEnabled { disableButton }
                }
            }

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.dictatorBody(11, weight: .medium))
                    .foregroundStyle(.orange)
            }
        }
        .task(id: setupRequested) {
            guard setupRequested else { return }
            defer { setupRequested = false }
            errorMessage = ""
            do {
                try await model.configureOfflineFallback()
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var setupButton: some View {
        let button = Button(setupTitle) { setupRequested = true }
            .disabled(setupRequested || !model.appleSpeechAvailable)
        if prominent {
            button.dictatorButton()
        } else {
            button.dictatorButton(.secondary)
        }
    }

    private var disableButton: some View {
        Button("Disable fallback") { model.disableOfflineFallback() }
            .dictatorButton(prominent ? .secondary : .ghost)
    }

    private var setupTitle: String {
        if setupRequested { return "Preparing model…" }
        return model.offlineFallbackEnabled ? "Repair offline fallback" : "Set up offline fallback"
    }
}
