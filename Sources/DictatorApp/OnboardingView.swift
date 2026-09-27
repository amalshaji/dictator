import DictatorCore
import SwiftUI

enum OnboardingStep: Int, CaseIterable {
    case welcome
    case permissions
    case provider
    case ready

    var next: Self? { Self(rawValue: rawValue + 1) }
    var previous: Self? { Self(rawValue: rawValue - 1) }
}

struct OnboardingView: View {
    let model: AppModel
    @State private var step: OnboardingStep = .welcome
    @State private var scratchText = ""
    @FocusState private var scratchFocused: Bool

    var body: some View {
        ZStack {
            DictatorDesign.paper.ignoresSafeArea()
            VStack(spacing: 0) {
                progress
                Group {
                    switch step {
                    case .welcome: welcome
                    case .permissions: permissions
                    case .provider: providerSetup
                    case .ready: ready
                    }
                }
                .frame(maxWidth: 620, maxHeight: .infinity)
                controls
            }
            .padding(38)
        }
        .task(id: step) {
            while step == .permissions && !Task.isCancelled {
                model.refreshPermissionState()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: step) { _, value in
            guard value == .ready else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                scratchFocused = true
            }
        }
    }

    private var progress: some View {
        HStack(spacing: 7) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { item in
                Capsule().fill(item.rawValue <= step.rawValue ? DictatorDesign.signalInk : DictatorDesign.fog)
                    .frame(width: item == step ? 34 : 12, height: 5)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            WaveMarkLarge()
            Text("Speak. Release. Keep moving.").font(.dictatorDisplay)
            Text("Record from the menu bar and turn speech into text on your clipboard. You can optionally enable system-wide shortcuts and direct insertion later.")
                .font(.dictatorBodyLarge).foregroundStyle(DictatorDesign.textSecondary).lineSpacing(4)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Choose how Dictator works").font(.dictatorDisplay)
            Text("Least privilege needs only your microphone. System-wide mode adds shortcuts and direct insertion, which macOS protects with additional permissions.")
                .font(.dictatorBodyLarge).foregroundStyle(DictatorDesign.textSecondary)
            HStack(spacing: 10) {
                accessModeChoice(
                    .leastPrivileges,
                    title: "Use with least privileges",
                    detail: "Menu bar recording · Clipboard delivery",
                    recommended: true
                )
                accessModeChoice(
                    .systemWide,
                    title: "Use system-wide",
                    detail: "Global shortcuts · Direct insertion",
                    recommended: false
                )
            }
            PermissionRow(
                title: "Microphone",
                detail: "Records only after you start a dictation",
                granted: model.microphoneGranted
            )
            if model.accessMode == .systemWide {
                PermissionRow(title: "Accessibility", detail: "Inserts text into the focused field", granted: model.accessibilityGranted)
                PermissionRow(title: "Input Monitoring", detail: "Detects shortcuts while another app is active", granted: model.inputMonitoringGranted)
            }
            Button(model.accessMode == .leastPrivileges ? "Allow microphone" : "Grant permissions") {
                Task { await model.requestOnboardingPermissions() }
            }
                .dictatorButton()
            if !permissionsReady {
                Text(model.accessMode == .leastPrivileges
                    ? "Allow microphone access to continue. No other macOS permission is required."
                    : "If System Settings opens, enable Dictator in the displayed list and come back here.")
                    .font(.dictatorBody).foregroundStyle(DictatorDesign.textError)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var providerSetup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Connect speech-to-text").font(.dictatorDisplay)
                Text("Apple keeps audio on this Mac after its initial model download. Cloud providers receive audio directly and keep their keys in macOS Keychain.")
                    .font(.dictatorBodyLarge).foregroundStyle(DictatorDesign.textSecondary)
                ProviderPicker(model: model, purpose: .speechToText, providers: model.sttMetadata, expandAppleSpeechByDefault: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Try it here").font(.dictatorDisplay)
                Spacer()
                if !scratchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label("Dictation received", systemImage: "checkmark.circle.fill")
                        .font(.dictatorCaption(weight: .medium)).foregroundStyle(DictatorDesign.textSuccess)
                }
            }
            Text(model.accessMode == .leastPrivileges
                ? "Start recording from the menu bar, stop from the pill, then press Command-V here to paste the copied transcript."
                : "Click the scratchpad, use your dictation shortcut while speaking, then stop. This uses the transcription option you just selected.")
                .font(.dictatorBodyLarge).foregroundStyle(DictatorDesign.textSecondary).lineSpacing(3)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $scratchText)
                    .focused($scratchFocused)
                    .font(.dictatorBodyLarge)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .frame(minHeight: 130)
                    .background(DictatorDesign.control, in: RoundedRectangle(cornerRadius: DictatorDesign.radiusHero, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DictatorDesign.radiusHero, style: .continuous).stroke(scratchFocused ? DictatorDesign.signalInk : DictatorDesign.fog, lineWidth: scratchFocused ? 2 : 1))
                if scratchText.isEmpty {
                    Text("Your dictation will appear here…")
                        .font(.dictatorBodyLarge).foregroundStyle(DictatorDesign.textSecondary.opacity(0.65))
                        .padding(.horizontal, 18).padding(.vertical, 20).allowsHitTesting(false)
                }
            }

            HStack {
                Label(model.accessMode == .leastPrivileges
                    ? "Record from the menu bar · Paste with ⌘V"
                    : model.dictateInstruction, systemImage: "waveform")
                    .font(.dictatorBody(weight: .semibold)).foregroundStyle(DictatorDesign.accentForeground)
                Spacer()
                if !scratchText.isEmpty {
                    Button("Clear") { scratchText = ""; scratchFocused = true }.dictatorButton(.ghost)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var controls: some View {
        HStack {
            if let previous = step.previous {
                Button("Back") { step = previous }.dictatorButton(.ghost)
            }
            Spacer()
            Button(controlTitle) {
                switch step {
                case .ready:
                    model.finishOnboarding()
                default:
                    if let next = step.next { step = next }
                }
            }
            .dictatorButton()
            .disabled((step == .permissions && !permissionsReady) || (step == .provider && !model.selectedSTTIsConfigured))
        }
    }

    private var controlTitle: String {
        switch step {
        case .ready: scratchText.isEmpty ? "Skip and finish" : "Finish onboarding"
        default: "Continue"
        }
    }

    private var permissionsReady: Bool {
        model.onboardingPermissionsReady
    }

    private func accessModeChoice(
        _ mode: AppAccessMode,
        title: String,
        detail: String,
        recommended: Bool
    ) -> some View {
        let selected = model.accessMode == mode
        return Button { model.setAccessMode(mode) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    Spacer()
                    if recommended {
                        Text("Recommended").font(.dictatorCaption(weight: .semibold)).foregroundStyle(DictatorDesign.focus)
                    }
                }
                Text(title).font(.dictatorBody(weight: .semibold))
                Text(detail).font(.dictatorCaption).foregroundStyle(DictatorDesign.textSecondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            .background(selected ? DictatorDesign.orchid.opacity(0.24) : DictatorDesign.control, in: RoundedRectangle(cornerRadius: DictatorDesign.radiusCard, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DictatorDesign.radiusCard, style: .continuous).stroke(selected ? DictatorDesign.focus : DictatorDesign.border, lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
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
