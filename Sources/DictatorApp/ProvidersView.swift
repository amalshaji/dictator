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
                    Text("Your keys stay in Keychain. Audio and text go directly to the provider you select.")
                        .font(.dictatorBody(14)).foregroundStyle(DictatorDesign.ink.opacity(0.56))
                }
                providerTypeSelector

                if tab == 0 {
                    providerList(ProviderRegistry.sttMetadata, purpose: .speechToText)
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
        HStack(spacing: 3) {
            providerTypeButton("Speech to text", icon: "waveform", value: 0)
            providerTypeButton("LLM cleanup", icon: "sparkles", value: 1)
        }
        .padding(3)
        .background(DictatorDesign.fog.opacity(0.8), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(DictatorDesign.border.opacity(0.7)))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Provider type")
    }

    private func providerTypeButton(_ title: String, icon: String, value: Int) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) { tab = value }
        } label: {
            Label(title, systemImage: icon)
                .font(.dictatorBody(12, weight: .semibold))
                .foregroundStyle(tab == value ? DictatorDesign.ink : DictatorDesign.muted)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(tab == value ? DictatorDesign.control : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .shadow(color: tab == value ? .black.opacity(0.06) : .clear, radius: 2, y: 1)
        }
        .buttonStyle(.plain)
    }

    private func providerList(_ providers: [ProviderMetadata], purpose: ProviderPurpose) -> some View {
        VStack(spacing: 0) {
            ForEach(providers) { provider in
                ProviderSetupRow(model: model, purpose: purpose, provider: provider)
                if provider.kind != providers.last?.kind { Divider() }
            }
        }
        .background(DictatorDesign.control, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(DictatorDesign.border))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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

    private var selected: Bool {
        switch purpose {
        case .speechToText: model.selectedSTT == provider.kind
        case .cleanup: model.selectedLLM == provider.kind
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Circle().fill(selected ? DictatorDesign.signalInk : DictatorDesign.fog).frame(width: 28, height: 28)
                        .overlay(Image(systemName: selected ? "checkmark" : "key.horizontal").font(.system(size: 10, weight: .bold)).foregroundStyle(selected ? .white : DictatorDesign.muted))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(provider.displayName).font(.dictatorBody(14, weight: .semibold))
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

            if expanded {
                VStack(alignment: .leading, spacing: 13) {
                    field("API key") { SecureField("Paste your API key", text: $apiKey).textFieldStyle(DictatorTextFieldStyle()) }
                    if provider.requiresAccountID { field("Account ID") { TextField("Enter account ID", text: $accountID).textFieldStyle(DictatorTextFieldStyle()) } }
                    if provider.kind == .openAICompatible { field("Base URL") { TextField("https://api.example.com/v1", text: $baseURL).textFieldStyle(DictatorTextFieldStyle()) } }
                    if provider.models.count > 1 {
                        field("Model") {
                            Picker("Model", selection: $selectedModel) { ForEach(provider.models, id: \.self) { Text($0).tag($0) } }
                                .labelsHidden().pickerStyle(.menu).controlSize(.large)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4).frame(height: 36)
                                .background(DictatorDesign.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(DictatorDesign.border))
                        }
                    } else {
                        field("Model") { TextField("Model", text: $selectedModel).textFieldStyle(DictatorTextFieldStyle()) }
                    }
                    HStack(spacing: 8) {
                        Button("Use this provider") { saveAndSelect() }.dictatorButton()
                        Button(testing ? "Testing…" : "Test connection") { Task { await testConnection() } }.disabled(testing || apiKey.isEmpty).dictatorButton(.secondary)
                    }
                }
                .padding(16)
                .background(DictatorDesign.paper.opacity(0.72))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onAppear {
            selectedModel = model.configuredModel(for: purpose, provider: provider.kind) ?? provider.defaultModel
            if let saved = model.credentials(purpose: purpose, provider: provider.kind) {
                apiKey = saved.apiKey
                accountID = saved.accountID ?? ""
                baseURL = saved.baseURL?.absoluteString ?? ""
                status = "Configured"
            }
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
            case .speechToText: model.selectedSTT = provider.kind
            case .cleanup: model.selectedLLM = provider.kind
            }
            status = "Configured"
        } catch { status = error.localizedDescription }
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

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
