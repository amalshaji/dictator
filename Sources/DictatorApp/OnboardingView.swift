import DictatorCore
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @State private var step = 0
    @State private var provider: ProviderKind = .groq
    @State private var apiKey = ""
    @State private var accountID = ""
    @State private var providerStatus = ""
    @State private var connecting = false
    @State private var scratchText = ""
    @FocusState private var scratchFocused: Bool
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            DictatorDesign.paper.ignoresSafeArea()
            VStack(spacing: 0) {
                progress
                Group {
                    switch step {
                    case 0: welcome
                    case 1: permissions
                    case 2: providerSetup
                    default: ready
                    }
                }
                .frame(maxWidth: 620, maxHeight: .infinity)
                controls
            }
            .padding(38)
        }
        .onReceive(timer) { _ in if step == 1 { model.refreshPermissionState() } }
        .onAppear { provider = model.selectedSTT }
        .onChange(of: step) { _, value in
            guard value == 3 else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                scratchFocused = true
            }
        }
    }

    private var progress: some View {
        HStack(spacing: 7) {
            ForEach(0..<4, id: \.self) { index in
                Capsule().fill(index <= step ? DictatorDesign.signalInk : DictatorDesign.fog)
                    .frame(width: index == step ? 34 : 12, height: 5)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            WaveMarkLarge()
            Text("Speak. Release. Keep moving.").font(.dictatorDisplay(38))
            Text("Dictator turns the Fn key into dictation anywhere on your Mac. Use Apple On-Device on supported Macs, or connect the cloud speech provider you prefer.")
                .font(.dictatorBody(16)).foregroundStyle(.secondary).lineSpacing(4)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Three permissions, one purpose").font(.dictatorDisplay(30))
            Text("macOS controls these individually. Grant them, then return here—Dictator detects changes automatically.")
                .font(.dictatorBody(14)).foregroundStyle(.secondary)
            permissionRow("Microphone", detail: "Records only while Fn is held", granted: model.microphoneGranted)
            permissionRow("Accessibility", detail: "Inserts text into the focused field", granted: model.accessibilityGranted)
            permissionRow("Input Monitoring", detail: "Detects Fn while another app is active", granted: model.inputMonitoringGranted)
            Button("Grant permissions") { Task { await model.requestOnboardingPermissions() } }
                .dictatorButton()
            if !permissionsReady {
                Text("If System Settings opens, enable Dictator in the displayed list and come back here.")
                    .font(.dictatorBody(12)).foregroundStyle(.orange)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var providerSetup: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Connect speech-to-text").font(.dictatorDisplay(30))
            Text("Apple keeps audio on this Mac after its initial model download. Cloud providers receive audio directly and keep their keys in macOS Keychain.")
                .font(.dictatorBody(14)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text("CHOOSE A PROVIDER").font(.dictatorUtility(9)).foregroundStyle(DictatorDesign.muted)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(model.sttMetadata, id: \.kind) { item in
                        providerChoice(kind: item.kind, name: item.displayName)
                    }
                }
            }
            if provider == .appleSpeech {
                appleSpeechSetup
            } else {
                SecureField("API key", text: $apiKey).textFieldStyle(DictatorTextFieldStyle())
                if provider == .cloudflare { TextField("Cloudflare account ID", text: $accountID).textFieldStyle(DictatorTextFieldStyle()) }
            }
            Button(connecting ? appleOrCloudProgressTitle : appleOrCloudActionTitle) { Task { await connect() } }
                .dictatorButton().disabled(connecting || (provider != .appleSpeech && apiKey.isEmpty))
            if !providerStatus.isEmpty {
                Text(providerStatus).font(.dictatorBody(12, weight: .medium))
                    .foregroundStyle(model.selectedSTTIsConfigured ? .green : .orange)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var appleSpeechSetup: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.appleSpeechLocales.isEmpty {
                Picker("Language", selection: Binding(
                    get: { model.selectedAppleSpeechLocaleIdentifier },
                    set: { model.selectAppleSpeechLocale($0) }
                )) {
                    ForEach(model.appleSpeechLocales) { locale in
                        Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                            .tag(locale.identifier)
                    }
                }
                .pickerStyle(.menu)
            }
            Text(model.appleSpeechStatusText)
                .font(.dictatorBody(12, weight: .medium))
                .foregroundStyle(model.appleSpeechReadiness.isReady ? DictatorDesign.focus : .secondary)
            if case let .downloading(_, progress) = model.appleSpeechReadiness {
                ProgressView(value: progress)
            }
        }
        .task { await model.refreshAppleSpeechSetup() }
    }

    private var appleOrCloudActionTitle: String {
        provider == .appleSpeech ? "Prepare and use Apple On-Device" : "Verify and save"
    }

    private var appleOrCloudProgressTitle: String {
        provider == .appleSpeech ? "Preparing model…" : "Verifying…"
    }

    private func providerChoice(kind: ProviderKind, name: String) -> some View {
        let selected = provider == kind
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { provider = kind }
            apiKey = ""
            accountID = ""
            providerStatus = ""
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(selected ? DictatorDesign.signalInk : DictatorDesign.fog)
                        .frame(width: 28, height: 28)
                    Image(systemName: selected ? "checkmark" : "waveform")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(selected ? .white : DictatorDesign.muted)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.dictatorBody(12.5, weight: .semibold)).foregroundStyle(DictatorDesign.ink)
                    Text(selected ? "Selected" : "Speech to text")
                        .font(.dictatorBody(10)).foregroundStyle(selected ? DictatorDesign.focus : DictatorDesign.muted)
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .background(selected ? DictatorDesign.orchid.opacity(0.24) : DictatorDesign.control, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? DictatorDesign.focus.opacity(0.65) : DictatorDesign.border, lineWidth: selected ? 1.5 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name) provider")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Try it here").font(.dictatorDisplay(32))
                Spacer()
                if !scratchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label("Dictation received", systemImage: "checkmark.circle.fill")
                        .font(.dictatorUtility(10)).foregroundStyle(.green)
                }
            }
            Text("Click the scratchpad, hold Fn while speaking, then release. This uses the transcription option you just selected.")
                .font(.dictatorBody(14)).foregroundStyle(.secondary).lineSpacing(3)

            HStack(spacing: 8) {
                example("Schedule lunch with Maya tomorrow")
                example("Draft a friendly follow-up email")
                example("Dictator understands product names")
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $scratchText)
                    .focused($scratchFocused)
                    .font(.dictatorBody(15))
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .frame(minHeight: 130)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(scratchFocused ? DictatorDesign.signalInk : DictatorDesign.fog, lineWidth: scratchFocused ? 2 : 1))
                if scratchText.isEmpty {
                    Text("Your dictation will appear here…")
                        .font(.dictatorBody(15)).foregroundStyle(.secondary.opacity(0.65))
                        .padding(.horizontal, 18).padding(.vertical, 20).allowsHitTesting(false)
                }
            }

            HStack {
                Label("Hold \(model.dictateShortcut.displayName) to speak", systemImage: "waveform")
                    .font(.dictatorBody(12, weight: .semibold)).foregroundStyle(DictatorDesign.signalInk)
                Spacer()
                if !scratchText.isEmpty {
                    Button("Clear") { scratchText = ""; scratchFocused = true }.dictatorButton(.ghost)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func example(_ text: String) -> some View {
        Text("“\(text)”")
            .font(.dictatorBody(11, weight: .medium)).foregroundStyle(DictatorDesign.ink.opacity(0.62))
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DictatorDesign.fog.opacity(0.75), in: RoundedRectangle(cornerRadius: 9))
            .lineLimit(2)
    }

    private var controls: some View {
        HStack {
            if step > 0 { Button("Back") { step -= 1 }.dictatorButton(.ghost) }
            Spacer()
            Button(step == 3 ? (scratchText.isEmpty ? "Skip and finish" : "Finish onboarding") : "Continue") {
                if step == 3 { model.finishOnboarding() } else { step += 1 }
            }
            .dictatorButton()
            .disabled((step == 1 && !permissionsReady) || (step == 2 && !model.selectedSTTIsConfigured))
        }
    }

    private var permissionsReady: Bool {
        model.microphoneGranted && model.accessibilityGranted && model.inputMonitoringGranted && model.shortcutsAvailable
    }

    private func permissionRow(_ title: String, detail: String, granted: Bool) -> some View {
        HStack(spacing: 13) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(granted ? .green : .secondary).font(.system(size: 19))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.dictatorBody(14, weight: .semibold))
                Text(detail).font(.dictatorBody(12)).foregroundStyle(.secondary)
            }
        }
    }

    private func connect() async {
        connecting = true
        defer { connecting = false }
        do {
            try await model.configureOnboardingProvider(kind: provider, apiKey: apiKey, accountID: accountID)
            providerStatus = provider == .appleSpeech ? "Apple On-Device is ready" : "Connection verified"
        } catch { providerStatus = error.localizedDescription }
    }
}

private struct WaveMarkLarge: View {
    var body: some View {
        HStack(spacing: 4) {
            ForEach([14.0, 26, 40, 24, 12], id: \.self) { height in
                Capsule().fill(DictatorDesign.signalInk).frame(width: 6, height: height)
            }
        }.frame(height: 44)
    }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
