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
                    providerList(metadata: ProviderRegistry.sttMetadata, purpose: "stt")
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
                    providerList(metadata: CleanupProviderRegistry.metadata, purpose: "llm")
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

    private func providerList(metadata: [Any], purpose: String) -> some View {
        VStack(spacing: 0) {
            if purpose == "stt" {
                ForEach(ProviderRegistry.sttMetadata, id: \.kind) { item in
                    ProviderSetupRow(model: model, purpose: purpose, kind: item.kind, name: item.displayName, defaultModel: item.defaultModel, models: item.models, requiresAccountID: item.requiresAccountID)
                    Divider()
                }
            } else {
                ForEach(CleanupProviderRegistry.metadata, id: \.kind) { item in
                    ProviderSetupRow(model: model, purpose: purpose, kind: item.kind, name: item.displayName, defaultModel: item.defaultModel, models: [item.defaultModel], requiresAccountID: item.requiresAccountID)
                    Divider()
                }
            }
        }
        .background(DictatorDesign.control, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(DictatorDesign.border))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct ProviderSetupRow: View {
    @ObservedObject var model: AppModel
    let purpose: String
    let kind: ProviderKind
    let name: String
    let defaultModel: String
    let models: [String]
    let requiresAccountID: Bool
    @State private var expanded = false
    @State private var apiKey = ""
    @State private var accountID = ""
    @State private var baseURL = ""
    @State private var selectedModel = ""
    @State private var status = "Not configured"
    @State private var testing = false

    private var selected: Bool { purpose == "stt" ? model.selectedSTT == kind : model.selectedLLM == kind }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Circle().fill(selected ? DictatorDesign.signalInk : DictatorDesign.fog).frame(width: 28, height: 28)
                        .overlay(Image(systemName: selected ? "checkmark" : "key.horizontal").font(.system(size: 10, weight: .bold)).foregroundStyle(selected ? .white : DictatorDesign.muted))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name).font(.dictatorBody(14, weight: .semibold))
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
                    if requiresAccountID { field("Account ID") { TextField("Enter account ID", text: $accountID).textFieldStyle(DictatorTextFieldStyle()) } }
                    if kind == .openAICompatible { field("Base URL") { TextField("https://api.example.com/v1", text: $baseURL).textFieldStyle(DictatorTextFieldStyle()) } }
                    if models.count > 1 {
                        field("Model") {
                            Picker("Model", selection: $selectedModel) { ForEach(models, id: \.self) { Text($0).tag($0) } }
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
            selectedModel = UserDefaults.standard.string(forKey: "\(purpose)Model.\(kind.rawValue)") ?? defaultModel
            if let saved = model.credentials(purpose: purpose, provider: kind) {
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
            let credentials = ProviderCredentials(apiKey: apiKey, accountID: accountID.nilIfEmpty, baseURL: URL(string: baseURL))
            try model.saveCredentials(credentials, purpose: purpose, provider: kind, model: selectedModel)
            if purpose == "stt" { model.selectedSTT = kind } else { model.selectedLLM = kind }
            status = "Configured"
        } catch { status = error.localizedDescription }
    }

    private func testConnection() async {
        testing = true
        defer { testing = false }
        do {
            let credentials = ProviderCredentials(apiKey: apiKey, accountID: accountID.nilIfEmpty, baseURL: URL(string: baseURL))
            if purpose == "stt", let provider = ProviderRegistry.sttProvider(for: kind) { try await provider.validate(credentials: credentials) }
            if purpose == "llm", let provider = CleanupProviderRegistry.provider(for: kind) { try await provider.validate(credentials: credentials) }
            status = "Connection verified"
        } catch { status = error.localizedDescription }
    }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
