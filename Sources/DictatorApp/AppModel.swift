import AppKit
import ApplicationServices
import AVFoundation
import Combine
import DictatorCore
import Foundation
import ServiceManagement

enum DictationPhase: Equatable { case idle, listening, processing }
enum ShortcutPurpose { case dictate, pasteLatest, openClipboard }

@MainActor
final class AppModel: ObservableObject {
    @Published var data = PersistedData()
    @Published var phase: DictationPhase = .idle
    @Published var selectedSTT: ProviderKind = .groq { didSet { defaults.set(selectedSTT.rawValue, forKey: "selectedSTT") } }
    @Published var selectedLLM: ProviderKind = .groq { didSet { defaults.set(selectedLLM.rawValue, forKey: "selectedLLM") } }
    @Published var cleanupEnabled = false { didSet { defaults.set(cleanupEnabled, forKey: "cleanupEnabled") } }
    @Published var lastError: String?
    @Published var requestedDestination: String?
    @Published var shortcutsAvailable = false
    @Published var accessibilityGranted = AXIsProcessTrusted()
    @Published var inputMonitoringGranted = CGPreflightListenEventAccess()
    @Published var microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @Published var onboardingComplete = UserDefaults.standard.bool(forKey: "onboardingComplete")
    @Published private(set) var dictateShortcut = GlobalShortcut.dictate
    @Published private(set) var pasteLatestShortcut = GlobalShortcut.pasteLatest
    @Published private(set) var openClipboardShortcut = GlobalShortcut.openClipboard
    @Published var selectedStyleID: UUID? = nil {
        didSet { defaults.set(selectedStyleID?.uuidString, forKey: "selectedStyleID") }
    }
    let pricing = PricingStore()

    private let defaults = UserDefaults.standard
    private let store = LocalStore(fileURL: LocalStore.applicationSupportURL())
    private let keychain = KeychainStore()
    private let recorder = AudioRecorder()
    private let hotkey = HotkeyMonitor()
    private let inserter = AccessibilityInserter()
    private let transcriptProcessor = TranscriptProcessor()
    private let transcriptRepairService = TranscriptRepairService()
    private let hud = FloatingPanelController()
    private var focusedTarget: FocusedTarget?

    init() {
        selectedSTT = ProviderKind(rawValue: defaults.string(forKey: "selectedSTT") ?? "") ?? .groq
        selectedLLM = ProviderKind(rawValue: defaults.string(forKey: "selectedLLM") ?? "") ?? .groq
        cleanupEnabled = defaults.bool(forKey: "cleanupEnabled")
        selectedStyleID = defaults.string(forKey: "selectedStyleID").flatMap(UUID.init(uuidString:))
        dictateShortcut = loadShortcut(forKey: "shortcut.dictate", fallback: .dictate)
        pasteLatestShortcut = loadShortcut(forKey: "shortcut.pasteLatest", fallback: .pasteLatest)
        openClipboardShortcut = loadShortcut(forKey: "shortcut.openClipboard", fallback: .openClipboard)
        configureHotkeys()
        recorder.onLevel = { [weak self] level in
            Task { @MainActor in self?.hud.model.push(level: level) }
        }
        hotkey.onPress = { [weak self] targetPID in
            Task { @MainActor in await self?.startDictation(targetProcessIdentifier: targetPID) }
        }
        hotkey.onRelease = { [weak self] in Task { @MainActor in await self?.stopDictation() } }
        hotkey.onPasteLatest = { [weak self] in Task { @MainActor in await self?.pasteClipboard() } }
        hotkey.onOpenClipboard = { [weak self] in Task { @MainActor in self?.openClipboard() } }
        let runningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if !runningTests {
            if onboardingComplete { requestRequiredPermissions() }
            startHotkeysIfPossible()
        }
        // Defer panel layout until SwiftUI has finished installing this StateObject.
        // Resizing an NSHostingView during AttributeGraph construction aborts on macOS 26.
        Task { @MainActor in
            await Task.yield()
            hud.show(.idle)
            await load()
        }
        if !runningTests { Task { @MainActor [weak self] in
            // TCC permission changes do not restart the process. Retry until the
            // event tap becomes available so Fn starts working immediately.
            while let self, !self.shortcutsAvailable {
                try? await Task.sleep(for: .seconds(1))
                self.startHotkeysIfPossible()
            }
        } }
    }

    func startDictation(targetProcessIdentifier: pid_t? = nil) async {
        guard phase == .idle else { return }
        guard await recorder.requestPermission() else {
            showError("Microphone permission is required")
            return
        }
        focusedTarget = inserter.captureFocusedTarget(processIdentifier: targetProcessIdentifier)
        do {
            try recorder.start()
            phase = .listening
            hud.show(.listening)
        } catch { showError(error.localizedDescription) }
    }

    func stopDictation() async {
        guard phase == .listening else { return }
        phase = .processing
        let pipelineStarted = ContinuousClock.now
        let audio = recorder.stop()
        guard audio.duration >= 0.15 else {
            phase = .idle
            hud.show(.error("Too short—hold \(dictateShortcut.displayName) while speaking"))
            hud.hideAfterDelay()
            return
        }
        await process(audio, pipelineStarted: pipelineStarted)
    }

    func cancelDictation() {
        guard phase == .listening else { return }
        recorder.cancel()
        phase = .idle
        hud.show(.success("Cancelled"))
        hud.hideAfterDelay()
    }

    private func process(_ audio: RecordedAudio, pipelineStarted: ContinuousClock.Instant) async {
        hud.show(.transcribing)
        do {
            guard let provider = ProviderRegistry.sttProvider(for: selectedSTT) else { throw ProviderError.unsupported("Provider is not available") }
            guard let credentials = try keychain.load(for: .speechToText, provider: selectedSTT) else { throw ProviderError.missingCredential("\(provider.metadata.displayName) API key") }
            let model = configuredModel(for: .speechToText, provider: selectedSTT) ?? provider.metadata.defaultModel
            let raw = try await transcribeWithRetry(provider: provider, audio: audio, options: .init(model: model, vocabulary: data.vocabulary), credentials: credentials)
            let cleanup = try cleanupConfiguration()
            if cleanup != nil { hud.show(.cleaning) }
            let processed = await transcriptProcessor.process(
                rawText: raw.text,
                selectedText: focusedTarget?.selection?.text,
                vocabulary: data.vocabulary,
                snippets: data.snippets,
                cleanup: cleanup
            )

            let finalText: String
            let cleanupResult: CleanupResult?
            let cleanupFallbackReason: String?
            switch processed {
            case .raw(let text):
                (finalText, cleanupResult, cleanupFallbackReason) = (text, nil, nil)
            case .cleaned(let result):
                (finalText, cleanupResult, cleanupFallbackReason) = (result.text, result, nil)
            case .fallback(let text, let reason):
                (finalText, cleanupResult, cleanupFallbackReason) = (text, nil, reason)
            case .failed(let reason):
                showError("Cleanup failed—selection unchanged: \(reason)")
                return
            }

            let requestedInsertion: TextInsertion
            if cleanupResult?.intent == .transformation {
                guard let selection = focusedTarget?.selection else {
                    showError("The selected text is no longer available")
                    return
                }
                requestedInsertion = .transformation(finalText, expectedSelection: selection)
            } else {
                requestedInsertion = .dictation(finalText)
            }

            let insertion = await inserter.insert(requestedInsertion, into: focusedTarget)
            let pipelineLatency = Self.elapsedSeconds(since: pipelineStarted)
            if case .privateClipboard = insertion {
                data.clipboard.insert(.init(text: finalText, rawText: raw.text, sourceBundleID: focusedTarget?.bundleIdentifier), at: 0)
            }
            showCompletion(insertion: insertion, cleanupFallbackReason: cleanupFallbackReason)
            data.transcripts.insert(.init(
                rawText: raw.text,
                finalText: finalText,
                sttProvider: selectedSTT,
                sttModel: model,
                sourceBundleID: focusedTarget?.bundleIdentifier,
                audioDuration: audio.duration,
                sttLatency: raw.latency,
                pipelineLatency: pipelineLatency,
                cleanup: cleanupResult.map(CleanupExecution.init(result:)),
                insertionOutcome: insertion.label
            ), at: 0)
            await persist()
            phase = .idle
            hud.hideAfterDelay()
        } catch {
            showError(error.localizedDescription)
        }
    }

    private static func elapsedSeconds(since instant: ContinuousClock.Instant) -> TimeInterval {
        let components = instant.duration(to: .now).components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private func transcribeWithRetry(provider: any SpeechToTextProvider, audio: RecordedAudio, options: TranscriptionOptions, credentials: ProviderCredentials) async throws -> TranscriptionResult {
        var last: Error?
        for attempt in 0..<3 {
            do { return try await provider.transcribe(audio: audio, options: options, credentials: credentials) }
            catch {
                last = error
                guard attempt < 2, isRetryable(error) else { throw error }
                try? await Task.sleep(for: .milliseconds(250 * (attempt + 1)))
            }
        }
        throw last ?? ProviderError.invalidResponse
    }

    private func isRetryable(_ error: Error) -> Bool {
        if case ProviderError.httpStatus(let status, _) = error { return [408, 429, 502, 503].contains(status) }
        return error is URLError
    }

    func credentials(purpose: ProviderPurpose, provider: ProviderKind) -> ProviderCredentials? {
        try? resolvedCredentials(purpose: purpose, provider: provider)
    }

    func saveCredentials(_ credentials: ProviderCredentials, purpose: ProviderPurpose, provider: ProviderKind, model: String) throws {
        guard !credentials.apiKey.isEmpty else { throw ProviderError.missingCredential("API key") }
        guard !model.isEmpty else { throw ProviderError.invalidConfiguration("Enter a model name.") }
        try keychain.save(credentials, for: purpose, provider: provider)
        defaults.set(model, forKey: modelKey(for: purpose, provider: provider))
        objectWillChange.send()
    }

    func saveVocabulary(_ entry: VocabularyEntry) throws {
        let entry = try PersonalizationValidator.validateVocabulary(entry, among: data.vocabulary)
        if let index = data.vocabulary.firstIndex(where: { $0.id == entry.id }) { data.vocabulary[index] = entry }
        else { data.vocabulary.insert(entry, at: 0) }
        schedulePersistence()
    }

    func setVocabularyEnabled(_ id: UUID, _ enabled: Bool) {
        guard let index = data.vocabulary.firstIndex(where: { $0.id == id }) else { return }
        data.vocabulary[index].isEnabled = enabled; schedulePersistence()
    }

    func deleteVocabulary(_ id: UUID) {
        data.vocabulary.removeAll { $0.id == id }
        schedulePersistence()
    }

    func saveStyle(_ style: WritingStyle) throws {
        let style = try PersonalizationValidator.validateStyle(style, among: data.styles)
        if let index = data.styles.firstIndex(where: { $0.id == style.id }) { data.styles[index] = style }
        else { data.styles.insert(style, at: 0); selectedStyleID = style.id }
        if !style.isEnabled, selectedStyleID == style.id { selectedStyleID = nil }
        schedulePersistence()
    }

    func setStyleEnabled(_ id: UUID, _ enabled: Bool) {
        guard let index = data.styles.firstIndex(where: { $0.id == id }) else { return }
        data.styles[index].isEnabled = enabled
        if !enabled, selectedStyleID == id { selectedStyleID = nil }
        schedulePersistence()
    }

    func selectStyle(_ id: UUID?) {
        guard let id else { selectedStyleID = nil; return }
        guard data.styles.contains(where: { $0.id == id && $0.isEnabled }) else { return }
        selectedStyleID = id
    }

    func deleteStyle(_ id: UUID) {
        data.styles.removeAll { $0.id == id }
        if selectedStyleID == id { selectedStyleID = nil }
        schedulePersistence()
    }

    func saveSnippet(_ snippet: SnippetEntry) throws {
        let snippet = try PersonalizationValidator.validateSnippet(snippet, among: data.snippets)
        if let index = data.snippets.firstIndex(where: { $0.id == snippet.id }) { data.snippets[index] = snippet }
        else { data.snippets.insert(snippet, at: 0) }
        schedulePersistence()
    }

    func setSnippetEnabled(_ id: UUID, _ enabled: Bool) {
        guard let index = data.snippets.firstIndex(where: { $0.id == id }) else { return }
        data.snippets[index].isEnabled = enabled
        schedulePersistence()
    }

    func deleteSnippet(_ id: UUID) {
        data.snippets.removeAll { $0.id == id }
        schedulePersistence()
    }

    func pasteClipboard(_ entry: ClipboardEntry? = nil) async {
        let item = entry ?? data.clipboard.first
        guard let item else { return }
        if await inserter.pasteIntoFrontmostApp(item.text) {
            hud.show(.success("Paste sent"))
            hud.hideAfterDelay()
        } else {
            showError("Could not post the paste shortcut")
        }
    }

    func copyTranscriptText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func pasteTranscriptText(_ text: String) async {
        if !(await inserter.pasteIntoFrontmostApp(text)) { showError("Could not post the paste shortcut") }
    }

    func appendRevision(_ revision: TranscriptRevision, to transcriptID: UUID) {
        guard let index = data.transcripts.firstIndex(where: { $0.id == transcriptID }) else { return }
        data.transcripts[index].revisions.append(revision)
        data.transcripts[index].preferredRevisionID = revision.id
        schedulePersistence()
    }

    func reprocessTranscript(_ transcriptID: UUID) async throws -> TranscriptRevision {
        guard let record = data.transcripts.first(where: { $0.id == transcriptID }) else {
            throw ProviderError.invalidConfiguration("Transcript is no longer available.")
        }
        return try await transcriptRepairService.reprocess(
            record: record,
            vocabulary: data.vocabulary,
            snippets: data.snippets,
            cleanup: try cleanupConfiguration()
        )
    }

    func teachDictator(incorrect: String, correct: String) throws {
        let incorrect = incorrect.trimmingCharacters(in: .whitespacesAndNewlines)
        let correct = correct.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !incorrect.isEmpty, !correct.isEmpty else {
            throw PersonalizationValidationError.emptyValue("Correction fields")
        }
        if var entry = data.vocabulary.first(where: { $0.value.caseInsensitiveCompare(correct) == .orderedSame }) {
            entry.variants.append(incorrect)
            try saveVocabulary(entry)
            return
        }
        try saveVocabulary(.init(value: correct, variants: [incorrect]))
    }

    func requestAccessibilityPermission() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        _ = CGRequestListenEventAccess()
        startHotkeysIfPossible()
    }

    func retryShortcuts() { startHotkeysIfPossible() }

    @discardableResult
    func setShortcut(_ shortcut: GlobalShortcut, for purpose: ShortcutPurpose) -> Bool {
        let others: [GlobalShortcut]
        switch purpose {
        case .dictate: others = [pasteLatestShortcut, openClipboardShortcut]
        case .pasteLatest: others = [dictateShortcut, openClipboardShortcut]
        case .openClipboard: others = [dictateShortcut, pasteLatestShortcut]
        }
        guard !others.contains(shortcut) else { return false }

        switch purpose {
        case .dictate: dictateShortcut = shortcut
        case .pasteLatest: pasteLatestShortcut = shortcut
        case .openClipboard: openClipboardShortcut = shortcut
        }
        persistShortcuts()
        configureHotkeys()
        return true
    }

    func resetShortcuts() {
        dictateShortcut = .dictate
        pasteLatestShortcut = .pasteLatest
        openClipboardShortcut = .openClipboard
        persistShortcuts()
        configureHotkeys()
    }

    func requestOnboardingPermissions() async {
        requestAccessibilityPermission()
        microphoneGranted = await recorder.requestPermission()
        refreshPermissionState()
    }

    func refreshPermissionState() {
        accessibilityGranted = AXIsProcessTrusted()
        inputMonitoringGranted = CGPreflightListenEventAccess()
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        startHotkeysIfPossible()
    }

    func configureOnboardingProvider(kind: ProviderKind, apiKey: String, accountID: String?) async throws {
        guard let provider = ProviderRegistry.sttProvider(for: kind) else { throw ProviderError.unsupported("Provider is unavailable") }
        let normalizedAccountID = accountID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let credentials = ProviderCredentials(
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            accountID: normalizedAccountID?.isEmpty == false ? normalizedAccountID : nil
        )
        try await provider.validate(credentials: credentials)
        try saveCredentials(credentials, purpose: .speechToText, provider: kind, model: provider.metadata.defaultModel)
        selectedSTT = kind
    }

    func finishOnboarding() {
        onboardingComplete = true
        defaults.set(true, forKey: "onboardingComplete")
    }

    var selectedSTTIsConfigured: Bool { credentials(purpose: .speechToText, provider: selectedSTT)?.apiKey.isEmpty == false }

    func configuredModel(for purpose: ProviderPurpose, provider: ProviderKind) -> String? {
        defaults.string(forKey: modelKey(for: purpose, provider: provider))
    }

    private func modelKey(for purpose: ProviderPurpose, provider: ProviderKind) -> String {
        "\(purpose.rawValue)Model.\(provider.rawValue)"
    }

    private func resolvedCredentials(purpose: ProviderPurpose, provider: ProviderKind) throws -> ProviderCredentials? {
        if let saved = try keychain.load(for: purpose, provider: provider) { return saved }
        guard case .cleanup = purpose, provider == selectedSTT else { return nil }
        return try keychain.load(for: .speechToText, provider: provider)
    }

    private func cleanupConfiguration() throws -> TranscriptCleanupConfiguration? {
        guard cleanupEnabled else { return nil }
        guard let provider = CleanupProviderRegistry.provider(for: selectedLLM) else {
            throw ProviderError.unsupported("Cleanup provider is not available")
        }
        guard let credentials = try resolvedCredentials(purpose: .cleanup, provider: selectedLLM) else {
            throw ProviderError.missingCredential("\(provider.metadata.displayName) cleanup API key")
        }
        let model = configuredModel(for: .cleanup, provider: selectedLLM) ?? provider.metadata.defaultModel
        let style = data.styles.first { $0.id == selectedStyleID && $0.isEnabled }?.instruction
        return TranscriptCleanupConfiguration(
            provider: provider,
            model: model,
            credentials: credentials,
            styleInstruction: style
        )
    }

    private func showCompletion(insertion: InsertionResult, cleanupFallbackReason: String?) {
        if let cleanupFallbackReason {
            lastError = "Cleanup failed: \(cleanupFallbackReason)"
            hud.show(.error("Cleanup failed—used raw transcript"))
            return
        }
        lastError = nil
        if case .privateClipboard = insertion {
            hud.show(.clipboard)
        } else {
            hud.show(.success("Paste sent"))
        }
    }

    private func requestRequiredPermissions() {
        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
    }

    private func startHotkeysIfPossible() {
        guard !hotkey.isRunning else {
            shortcutsAvailable = true
            accessibilityGranted = AXIsProcessTrusted()
            inputMonitoringGranted = CGPreflightListenEventAccess()
            return
        }
        do {
            try hotkey.start()
            shortcutsAvailable = true
            if lastError == HotkeyError.permissionRequired.localizedDescription { lastError = nil }
        } catch {
            shortcutsAvailable = false
            lastError = error.localizedDescription
        }
    }

    private func configureHotkeys() {
        hotkey.configure(
            dictate: dictateShortcut,
            pasteLatest: pasteLatestShortcut,
            openClipboard: openClipboardShortcut
        )
    }

    private func loadShortcut(forKey key: String, fallback: GlobalShortcut) -> GlobalShortcut {
        guard let data = defaults.data(forKey: key),
              let shortcut = try? JSONDecoder().decode(GlobalShortcut.self, from: data)
        else { return fallback }
        return shortcut
    }

    private func persistShortcuts() {
        let encoder = JSONEncoder()
        defaults.set(try? encoder.encode(dictateShortcut), forKey: "shortcut.dictate")
        defaults.set(try? encoder.encode(pasteLatestShortcut), forKey: "shortcut.pasteLatest")
        defaults.set(try? encoder.encode(openClipboardShortcut), forKey: "shortcut.openClipboard")
    }

    var launchesAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            objectWillChange.send()
        } catch { lastError = error.localizedDescription }
    }

    private func openClipboard() {
        requestedDestination = "Clipboard"
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.title == "Dictator" })?.makeKeyAndOrderFront(nil)
    }

    private func load() async {
        do {
            data = try await store.load()
            if let selectedStyleID, !data.styles.contains(where: { $0.id == selectedStyleID && $0.isEnabled }) { self.selectedStyleID = nil }
        } catch { lastError = error.localizedDescription }
    }

    private func schedulePersistence() {
        Task { @MainActor [weak self] in await self?.persist() }
    }

    private func persist() async {
        let snapshot = data
        do { try await store.save(snapshot) }
        catch { lastError = "Could not save local data: \(error.localizedDescription)" }
    }

    private func showError(_ message: String) {
        lastError = message
        phase = .idle
        hud.show(.error(message))
        hud.hideAfterDelay()
    }
}
