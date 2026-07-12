import DictatorCore
import SwiftUI

struct ProvidersView: View {
    @ObservedObject var model: AppModel
    @State private var tab = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Providers").font(.dictatorDisplay(30))
                    Text("Apple transcription stays on your Mac. Cloud audio goes directly to the provider you select, and optional cleanup sends transcript text only.")
                        .font(.dictatorBody(14)).foregroundStyle(DictatorDesign.ink.opacity(0.56))
                }
                providerTypeSelector

                if tab == 0 {
                    providerList(model.sttMetadata, purpose: .speechToText)
                } else {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Clean up transcripts").font(.dictatorBody(13, weight: .semibold))
                            Text("Improve punctuation and apply your selected style.").font(.dictatorBody(11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $model.cleanupEnabled).labelsHidden().toggleStyle(.switch).tint(DictatorDesign.signalInk)
                    }
                    .padding(14)
                    .background(DictatorDesign.control, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(DictatorDesign.border))
                    providerList(CleanupProviderRegistry.metadata, purpose: .cleanup)
                }
            }
            .frame(maxWidth: DictatorDesign.contentWidth, alignment: .leading)
            .padding(.horizontal, 42).padding(.vertical, 36)
        }
    }

    private var providerTypeSelector: some View {
        DictatorSegmentedSwitcher(
            label: "Provider type",
            options: [
                .init(title: "Speech to text", icon: "waveform"),
                .init(title: "LLM cleanup", icon: "sparkles")
            ],
            selection: $tab
        )
    }

    private func providerList(_ providers: [ProviderMetadata], purpose: ProviderPurpose) -> some View {
        VStack(spacing: 0) {
            ForEach(providers) { provider in
                if provider.kind == .appleSpeech {
                    AppleSpeechSetupRow(model: model)
                } else {
                    ProviderSetupRow(model: model, purpose: purpose, provider: provider)
                }
                if provider.kind != providers.last?.kind { Divider() }
            }
        }
        .background(DictatorDesign.control, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(DictatorDesign.border))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct AppleSpeechSetupRow: View {
    @ObservedObject var model: AppModel
    @State private var expanded = false
    @State private var primarySetupRequested = false

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
                    .font(.dictatorBody(12)).foregroundStyle(.secondary)

                AppleSpeechModelSetupView(model: model)

                HStack(spacing: 8) {
                    Button(actionTitle) { primarySetupRequested = true }
                        .dictatorButton()
                        .disabled(actionDisabled || primarySetupRequested)
                    if case .failed = model.appleSpeech.state.readiness {
                        Button("Retry status") { Task { await model.appleSpeech.refresh() } }
                            .dictatorButton(.secondary)
                    }
                }

                Divider().overlay(DictatorDesign.border)

                VStack(alignment: .leading, spacing: 8) {
                    Text("OFFLINE FALLBACK")
                        .font(.dictatorUtility(9)).foregroundStyle(DictatorDesign.muted)
                    OfflineFallbackControl(
                        model: model,
                        selectedAsPrimary: selected,
                        description: fallbackDescription
                    )
                }
            }
        }
        .task(id: primarySetupRequested) {
            guard primarySetupRequested else { return }
            defer { primarySetupRequested = false }
            await prepareOrSelect()
        }
    }

    private var fallbackDescription: String {
        if selected {
            return "Dictation already runs locally. Cloud cleanup pauses automatically when the Mac is offline."
        }
        return "Use Apple On-Device only when your selected cloud speech provider can’t connect."
    }

    private var statusColor: Color {
        model.appleSpeech.state.readiness.isReady ? DictatorDesign.focus : DictatorDesign.muted
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
        if !model.appleSpeech.state.readiness.isReady { await model.appleSpeech.prepare() }
        if model.appleSpeech.state.readiness.isReady {
            do { try model.selectSTT(.appleSpeech) }
            catch { model.lastError = error.localizedDescription }
        }
    }

}

private struct ProviderSetupRow: View {
    @ObservedObject var model: AppModel
    let purpose: ProviderPurpose
    let provider: ProviderMetadata
    @State private var expanded = false
    @State private var apiKey = ""
    @State private var accountID = ""
    @State private var baseURL = ""
    @State private var selectedModel = ""
    @State private var status = "Not configured"
    @State private var testing = false
    @State private var loadedCredentials = false

    private var selected: Bool {
        switch purpose {
        case .speechToText: model.selectedSTT == provider.kind
        case .cleanup: model.selectedLLM == provider.kind
        }
    }

    var body: some View {
        ProviderAccordionRow(
            expanded: $expanded,
            selected: selected,
            icon: "key.horizontal",
            title: provider.displayName,
            status: status,
            statusColor: statusColor
        ) {
            VStack(alignment: .leading, spacing: 13) {
                field("API key") { SecureField("Paste your API key", text: $apiKey).textFieldStyle(DictatorTextFieldStyle()) }
                if provider.requiresAccountID { field("Account ID") { TextField("Enter account ID", text: $accountID).textFieldStyle(DictatorTextFieldStyle()) } }
                if provider.kind == .openAICompatible { field("Base URL") { TextField("https://api.example.com/v1", text: $baseURL).textFieldStyle(DictatorTextFieldStyle()) } }
                if provider.models.count > 1 {
                    field("Model") {
                        DictatorMenuField(
                            label: "Model",
                            options: provider.models.map { .init(value: $0, label: $0) },
                            selection: $selectedModel
                        )
                    }
                } else {
                    field("Model") { TextField("Model", text: $selectedModel).textFieldStyle(DictatorTextFieldStyle()) }
                }
                HStack(spacing: 8) {
                    Button("Use this provider") { saveAndSelect() }.dictatorButton()
                    Button(testing ? "Testing…" : "Test connection") { Task { await testConnection() } }
                        .disabled(testing || apiKey.isEmpty)
                        .dictatorButton(.secondary)
                }
            }
        }
        .onAppear {
            selectedModel = model.configuredModel(for: purpose, provider: provider.kind) ?? provider.defaultModel
        }
        .onChange(of: expanded) { _, isExpanded in
            if isExpanded { loadCredentialsIfNeeded() }
        }
    }

    private var statusColor: Color {
        status == "Configured" || status == "Connection verified" ? DictatorDesign.focus : DictatorDesign.muted
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.dictatorBody(11, weight: .semibold)).foregroundStyle(DictatorDesign.ink.opacity(0.72))
            content()
        }
    }

    private func saveAndSelect() {
        do {
            let credentials = try enteredCredentials()
            try model.saveCredentials(credentials, purpose: purpose, provider: provider.kind, model: selectedModel.trimmed)
            switch purpose {
            case .speechToText: try model.selectSTT(provider.kind)
            case .cleanup: model.selectedLLM = provider.kind
            }
            status = "Configured"
        } catch { status = error.localizedDescription }
    }

    private func loadCredentialsIfNeeded() {
        guard !loadedCredentials else { return }
        loadedCredentials = true
        guard let saved = model.credentials(purpose: purpose, provider: provider.kind) else { return }
        apiKey = saved.apiKey
        accountID = saved.accountID ?? ""
        baseURL = saved.baseURL?.absoluteString ?? ""
        status = "Configured"
    }

    private func testConnection() async {
        testing = true
        defer { testing = false }
        do {
            let credentials = try enteredCredentials()
            switch purpose {
            case .speechToText:
                guard let implementation = ProviderRegistry.sttProvider(for: provider.kind) else {
                    throw ProviderError.invalidConfiguration("This speech provider is unavailable.")
                }
                try await implementation.validate(credentials: credentials)
            case .cleanup:
                guard let implementation = CleanupProviderRegistry.provider(for: provider.kind) else {
                    throw ProviderError.invalidConfiguration("This cleanup provider is unavailable.")
                }
                try await implementation.validate(credentials: credentials)
            }
            status = "Connection verified"
        } catch { status = error.localizedDescription }
    }

    private func enteredCredentials() throws -> ProviderCredentials {
        let key = apiKey.trimmed
        guard !key.isEmpty else { throw ProviderError.missingCredential("API key") }

        let normalizedAccountID = accountID.trimmed.nilIfEmpty
        if provider.requiresAccountID, normalizedAccountID == nil {
            throw ProviderError.missingCredential("account ID")
        }

        let enteredBaseURL = baseURL.trimmed
        let url = enteredBaseURL.isEmpty ? nil : URL(string: enteredBaseURL)
        if provider.kind == .openAICompatible {
            guard let url,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil
            else { throw ProviderError.invalidConfiguration("Enter a valid HTTP or HTTPS base URL.") }
        }
        return ProviderCredentials(apiKey: key, accountID: normalizedAccountID, baseURL: url)
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
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(selected ? .white : DictatorDesign.muted)
                        }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.dictatorBody(14, weight: .semibold))
                        Text(status).font(.dictatorBody(10.5, weight: .medium)).foregroundStyle(statusColor)
                    }
                    Spacer()
                    if selected {
                        Text("Active").font(.dictatorUtility(9)).foregroundStyle(DictatorDesign.signalInk)
                            .padding(.horizontal, 8).frame(height: 22)
                            .background(DictatorDesign.orchid.opacity(0.45), in: Capsule())
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 180 : 0)).foregroundStyle(DictatorDesign.muted)
                        .frame(width: 28, height: 28)
                        .background(DictatorDesign.fog.opacity(0.65), in: Circle())
                }
                .contentShape(Rectangle()).padding(.horizontal, 16).padding(.vertical, 13)
            }
            .buttonStyle(.plain)

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
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
