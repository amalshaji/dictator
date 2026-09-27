import DictatorCore
import SwiftUI

/// Shared provider selection + setup list used by both the Pipeline "Providers"
/// screen and onboarding's speech-to-text step, so both surfaces expand rows,
/// save credentials, and test connections identically.
struct ProviderPicker: View {
    let model: AppModel
    let purpose: ProviderPurpose
    let providers: [ProviderMetadata]
    var expandAppleSpeechByDefault: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            ForEach(providers) { provider in
                if provider.kind == .appleSpeech {
                    AppleSpeechSetupRow(model: model, initiallyExpanded: expandAppleSpeechByDefault)
                } else {
                    ProviderSetupRow(model: model, purpose: purpose, provider: provider)
                }
                if provider.kind != providers.last?.kind { Divider() }
            }
        }
        .dictatorCard()
    }
}

/// Outcome of testing a provider's credentials. A pure enum (no SwiftUI
/// dependency) so its label/glyph mapping can be unit-tested directly.
enum ConnectionTestState: Equatable {
    case idle
    case testing
    case connected
    case failed(String)

    var label: String {
        switch self {
        case .idle: "Test connection"
        case .testing: "Testing…"
        case .connected: "Connected"
        case .failed(let message): message
        }
    }

    var glyph: String? {
        switch self {
        case .idle, .testing: nil
        case .connected: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

private struct AppleSpeechSetupRow: View {
    let model: AppModel
    @State private var expanded: Bool
    @State private var primarySetupRequested = false
    @State private var errorMessage: String?

    init(model: AppModel, initiallyExpanded: Bool = false) {
        self.model = model
        _expanded = State(initialValue: initiallyExpanded)
    }

    private var selected: Bool { model.selectedSTT == .appleSpeech }

    var body: some View {
        ProviderAccordionRow(
            expanded: $expanded,
            selected: selected,
            icon: "waveform",
            title: "Apple On-Device",
            status: model.appleSpeech.statusText,
            statusColor: statusColor
        ) {
            VStack(alignment: .leading, spacing: 13) {
                Text("Audio is transcribed entirely on this Mac after the initial language model download.")
                    .font(.dictatorBody).foregroundStyle(DictatorDesign.textSecondary)

                AppleSpeechModelSetupView(model: model)

                HStack(spacing: 8) {
                    Button(actionTitle) { primarySetupRequested = true }
                        .dictatorButton()
                        .disabled(actionDisabled || primarySetupRequested)
                    switch model.appleSpeech.state.readiness {
                    case .failed, .unavailable:
                        Button("Retry status") { Task { await model.appleSpeech.refresh() } }
                            .dictatorButton(.secondary)
                    default:
                        EmptyView()
                    }
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.dictatorCaption(weight: .medium))
                        .foregroundStyle(DictatorDesign.textError)
                }
            }
        }
        .task(id: primarySetupRequested) {
            guard primarySetupRequested else { return }
            defer { primarySetupRequested = false }
            await prepareOrSelect()
        }
    }

    private var statusColor: Color {
        model.appleSpeech.state.readiness.isReady ? DictatorDesign.focus : DictatorDesign.textSecondary
    }

    private var actionTitle: String {
        switch model.appleSpeech.state.readiness {
        case .ready: selected ? "Apple On-Device is active" : "Use Apple On-Device"
        case .downloadRequired: "Download speech model"
        case .failed: "Retry download"
        case .checking: "Checking availability…"
        case .downloading: "Downloading…"
        case .unavailable: "Unavailable"
        }
    }

    private var actionDisabled: Bool {
        switch model.appleSpeech.state.readiness {
        case .checking, .downloading, .unavailable: true
        case .ready: selected
        case .downloadRequired, .failed: false
        }
    }

    private func prepareOrSelect() async {
        errorMessage = nil
        if !model.appleSpeech.state.readiness.isReady { await model.appleSpeech.prepare() }
        if model.appleSpeech.state.readiness.isReady {
            do { try model.selectSTT(.appleSpeech) }
            catch { errorMessage = error.localizedDescription }
        }
    }

}

private struct ProviderSetupRow: View {
    let model: AppModel
    let purpose: ProviderPurpose
    let provider: ProviderMetadata
    @State private var expanded = false
    @State private var apiKey = ""
    @State private var baseURL = ""
    @State private var selectedModel = ""
    @State private var configured = false
    @State private var replacingKey = false
    @State private var errorMessage: String?
    @State private var testState: ConnectionTestState = .idle

    private var selected: Bool {
        switch purpose {
        case .speechToText: model.selectedSTT == provider.kind
        case .cleanup: model.selectedLLM == provider.kind
        }
    }

    /// True only when the provider has exactly one real (non-empty) model, i.e.
    /// there is nothing to choose. A provider whose single "model" is an empty
    /// string (the custom OpenAI-compatible provider) still needs free-form entry.
    private var hasFixedModel: Bool {
        provider.models.count == 1 && !(provider.models.first ?? "").isEmpty
    }

    private var hasUsableCredentials: Bool {
        (configured && !replacingKey) || !apiKey.trimmed.isEmpty
    }

    var body: some View {
        ProviderAccordionRow(
            expanded: $expanded,
            selected: selected,
            icon: "key.horizontal",
            title: provider.displayName,
            status: configured ? "Configured" : "Not configured",
            statusColor: configured ? DictatorDesign.focus : DictatorDesign.textSecondary
        ) {
            VStack(alignment: .leading, spacing: 13) {
                FormField("API key") {
                    if configured, !replacingKey {
                        HStack {
                            Text("Key saved").font(.dictatorCaption).foregroundStyle(DictatorDesign.textSecondary)
                            Spacer()
                            Button("Replace") {
                                replacingKey = true
                                apiKey = ""
                                testState = .idle
                            }.dictatorButton(.ghost)
                                .help("Replace the stored API key")
                        }
                    } else {
                        SecureField("Paste your API key", text: $apiKey)
                            .textFieldStyle(DictatorTextFieldStyle())
                            .onChange(of: apiKey) { _, _ in testState = .idle }
                    }
                }
                if provider.kind == .openAICompatible {
                    FormField("Base URL") {
                        TextField("https://api.example.com/v1", text: $baseURL)
                            .textFieldStyle(DictatorTextFieldStyle())
                            .onChange(of: baseURL) { _, _ in testState = .idle }
                    }
                }
                if provider.models.count > 1 {
                    FormField("Model") {
                        DictatorMenuField(
                            label: "Model",
                            options: provider.models.map { .init(value: $0, label: $0) },
                            selection: $selectedModel
                        )
                    }
                } else if hasFixedModel {
                    FormField("Model") {
                        Text(provider.models[0]).font(.dictatorBody).foregroundStyle(DictatorDesign.textSecondary)
                    }
                } else {
                    FormField("Model") { TextField("Model", text: $selectedModel).textFieldStyle(DictatorTextFieldStyle()) }
                }
                HStack(spacing: 8) {
                    Button("Use this provider") { saveAndSelect() }.dictatorButton()
                    testConnectionControl
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.dictatorCaption(weight: .medium))
                        .foregroundStyle(DictatorDesign.textError)
                }
            }
        }
        .onAppear {
            selectedModel = model.configuredModel(for: purpose, provider: provider.kind) ?? provider.defaultModel
            configured = model.isProviderConfigured(purpose: purpose, provider: provider.kind)
        }
        .onChange(of: expanded) { _, isExpanded in
            errorMessage = nil
            testState = .idle
            replacingKey = false
            apiKey = ""
            if isExpanded {
                configured = model.isProviderConfigured(purpose: purpose, provider: provider.kind)
                baseURL = model.credentials(purpose: purpose, provider: provider.kind)?.baseURL?.absoluteString ?? ""
            } else {
                baseURL = ""
            }
        }
    }

    @ViewBuilder
    private var testConnectionControl: some View {
        switch testState {
        case .idle:
            Button(testState.label) { Task { await testConnection() } }
                .dictatorButton(.secondary)
                .disabled(!hasUsableCredentials)
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(testState.label).font(.dictatorCaption).foregroundStyle(DictatorDesign.textSecondary)
            }
        case .connected:
            Label(testState.label, systemImage: testState.glyph ?? "checkmark.circle.fill")
                .font(.dictatorCaption(weight: .medium)).foregroundStyle(DictatorDesign.textSuccess)
        case .failed:
            Label(testState.label, systemImage: testState.glyph ?? "exclamationmark.triangle.fill")
                .font(.dictatorCaption(weight: .medium)).foregroundStyle(DictatorDesign.textError)
        }
    }

    private func saveAndSelect() {
        do {
            let credentials = try credentialsForAction()
            try model.saveCredentials(credentials, purpose: purpose, provider: provider.kind, model: selectedModel.trimmed)
            switch purpose {
            case .speechToText: try model.selectSTT(provider.kind)
            case .cleanup: model.selectedLLM = provider.kind
            }
            errorMessage = nil
            configured = true
            replacingKey = false
            apiKey = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func testConnection() async {
        testState = .testing
        do {
            let credentials = try credentialsForAction()
            try await model.testProviderConnection(
                purpose: purpose,
                provider: provider.kind,
                model: selectedModel.trimmed,
                credentials: credentials
            )
            testState = .connected
        } catch {
            testState = .failed(error.localizedDescription)
        }
    }

    /// Uses the already-saved credential when the field is left blank (i.e. the
    /// user isn't replacing a saved key), so the row never has to load a saved
    /// secret into visible/bound field state to act on it. The base URL always
    /// comes from the current field, even when reusing a stored key, so editing
    /// it isn't silently dropped on Save/Test.
    private func credentialsForAction() throws -> ProviderCredentials {
        if configured, !replacingKey, apiKey.trimmed.isEmpty {
            guard let existing = model.credentials(purpose: purpose, provider: provider.kind) else {
                throw ProviderError.missingCredential("API key")
            }
            return ProviderCredentials(apiKey: existing.apiKey, baseURL: try resolvedBaseURL())
        }
        return try enteredCredentials()
    }

    private func enteredCredentials() throws -> ProviderCredentials {
        let key = apiKey.trimmed
        guard !key.isEmpty else { throw ProviderError.missingCredential("API key") }
        return ProviderCredentials(apiKey: key, baseURL: try resolvedBaseURL())
    }

    private func resolvedBaseURL() throws -> URL? {
        let enteredBaseURL = baseURL.trimmed
        let url = enteredBaseURL.isEmpty ? nil : URL(string: enteredBaseURL)
        if provider.kind == .openAICompatible {
            guard let url,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil
            else { throw ProviderError.invalidConfiguration("Enter a valid HTTP or HTTPS base URL.") }
        }
        return url
    }
}

private struct ProviderAccordionRow<Content: View>: View {
    @Binding var expanded: Bool
    let selected: Bool
    let icon: String
    let title: String
    let status: String
    let statusColor: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Circle()
                        .fill(selected ? DictatorDesign.signalInk : DictatorDesign.fog)
                        .frame(width: 28, height: 28)
                        .overlay {
                            Image(systemName: selected ? "checkmark" : icon)
                                .font(DictatorDesign.glyphFont(size: 10, weight: .bold))
                                .foregroundStyle(selected ? .white : DictatorDesign.textSecondary)
                        }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.dictatorBodyLarge(weight: .semibold))
                        Text(status).font(.dictatorCaption(weight: .medium)).foregroundStyle(statusColor)
                    }
                    Spacer()
                    if selected {
                        Text("Active").font(.dictatorCaption(weight: .semibold)).foregroundStyle(Color.white)
                            .padding(.horizontal, 8).frame(height: 22)
                            .background(DictatorDesign.accentFill, in: Capsule())
                    }
                    Image(systemName: "chevron.down")
                        .font(DictatorDesign.glyphFont(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 180 : 0)).foregroundStyle(DictatorDesign.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(DictatorDesign.fog.opacity(0.65), in: Circle())
                }
                .contentShape(Rectangle()).padding(.horizontal, 16).padding(.vertical, 13)
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide \(title) settings" : "Show \(title) settings")

            VStack(spacing: 0) {
                if expanded {
                    content
                        .padding(16)
                        .background(DictatorDesign.paper.opacity(0.72))
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .clipped()
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
