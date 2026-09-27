import ApplicationServices
import AVFoundation
import DictatorCore
import Foundation
import Observation
import ServiceManagement

enum DictationPhase: Equatable { case idle, listening, processing }
enum ShortcutPurpose { case dictate, pasteLatest }

private enum StandardDictationDelivery {
    case clipboard
    case focusedTarget(FocusedTarget?)

    var target: FocusedTarget? {
        guard case .focusedTarget(let target) = self else { return nil }
        return target
    }
}

private enum ActiveDictationRun {
    case standard(StandardDictationDelivery)
}

@MainActor
@Observable
final class AppModel {
    var data = PersistedData()
    var phase: DictationPhase = .idle
    private(set) var selectedSTT: ProviderKind = .groq
    var selectedLLM: ProviderKind = .groq { didSet { defaults.set(selectedLLM.rawValue, forKey: "selectedLLM") } }
    var cleanupEnabled = false { didSet { defaults.set(cleanupEnabled, forKey: "cleanupEnabled") } }
    var lastError: String?
    var shortcutsAvailable = false
    var accessibilityGranted = AXIsProcessTrusted()
    var inputMonitoringGranted = CGPreflightListenEventAccess()
    var microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    var launchesAtLogin = SMAppService.mainApp.status == .enabled
    var onboardingComplete = false
    private var accessConfiguration = AppAccessConfiguration(
        mode: .leastPrivileges,
        systemWideInsertionMode: .insert
    )
    private(set) var dictateShortcut = GlobalShortcut.dictate
    private(set) var dictateActivationMode = HotkeyActivationMode.hold
    private(set) var pasteLatestShortcut = GlobalShortcut.pasteLatest
    var selectedStyleID: UUID? = nil {
        didSet { defaults.set(selectedStyleID?.uuidString, forKey: "selectedStyleID") }
    }
    private(set) var cleanupCustomInstruction = ""
    static let maximumCleanupInstructionLength = 2_000
    let appleSpeech: AppleSpeechCoordinator

    var accessMode: AppAccessMode { accessConfiguration.mode }
    var insertionMode: InsertionMode { accessConfiguration.insertionMode }

    private let defaults: UserDefaults
    private let store: LocalStore
    private let keychain: any CredentialStoring
    private let transcriptionCoordinator: any TranscriptionCoordinating
    private let recorder: any AudioRecording
    private let hotkeys: HotkeyLifecycleController
    private let inserter: any FocusedTargetInserting
    private let clipboardWriter: any ClipboardWriting
    private let providerConnections: ProviderConnectionService
    private let transcriptProcessor = TranscriptProcessor()
    private let hud = FloatingPanelController()
    @ObservationIgnored private var activeRun: ActiveDictationRun?
    @ObservationIgnored private var activeRunID: UUID?
    @ObservationIgnored private var initialLoadTask: Task<Void, Never>?
    @ObservationIgnored private var didCompleteInitialLoad = false
    @ObservationIgnored private var credentialCache: [String: ProviderCredentials?] = [:]

    convenience init() {
        self.init(
            keychain: KeychainStore(),
            appleSpeechProvider: Self.defaultAppleSpeechProvider(),
            defaults: .standard
        )
    }

    init(
        keychain: any CredentialStoring,
        appleSpeechProvider: (any LocalSpeechTranscribing)?,
        defaults: UserDefaults,
        hotkeys: HotkeyLifecycleController = HotkeyLifecycleController(),
        recorder: any AudioRecording = AudioRecorder(),
        transcriptionCoordinator: (any TranscriptionCoordinating)? = nil,
        inserter: any FocusedTargetInserting = AccessibilityInserter(),
        clipboardWriter: any ClipboardWriting = SystemClipboardWriter()
    ) {
        let runningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        self.defaults = defaults
        store = LocalStore(fileURL: runningTests
            ? FileManager.default.temporaryDirectory.appending(path: "DictatorTests-\(UUID().uuidString).json")
            : LocalStore.applicationSupportURL())
        self.keychain = keychain
        self.hotkeys = hotkeys
        self.recorder = recorder
        self.inserter = inserter
        self.clipboardWriter = clipboardWriter
        providerConnections = ProviderConnectionService()
        let appleSpeech = AppleSpeechCoordinator(
            provider: appleSpeechProvider,
            selectedLocaleIdentifier: defaults.string(forKey: "appleSpeechLocale") ?? Locale.current.identifier,
            persistSelection: { defaults.set($0, forKey: "appleSpeechLocale") }
        )
        self.appleSpeech = appleSpeech
        self.transcriptionCoordinator = transcriptionCoordinator ?? TranscriptionCoordinator(
            keychain: keychain,
            appleSpeech: appleSpeech
        )
        selectedSTT = STTProviderSelection.resolve(
            savedRawValue: defaults.string(forKey: "selectedSTT"),
            appleSpeechAvailable: appleSpeechProvider != nil,
            lastCloudRawValue: defaults.string(forKey: "lastCloudSTT"),
            existingInstallation: defaults.object(forKey: "onboardingComplete") != nil
        )
        let savedLLMRawValue = defaults.string(forKey: "selectedLLM")
        if let savedLLMRawValue {
            if let parsed = ProviderKind(rawValue: savedLLMRawValue) {
                selectedLLM = parsed
                cleanupEnabled = defaults.bool(forKey: "cleanupEnabled")
            } else {
                // The saved provider no longer exists (e.g. a retired cleanup
                // provider). Leaving cleanup on would point it at a provider
                // with no stored key, failing every dictation.
                selectedLLM = .groq
                cleanupEnabled = false
            }
        } else {
            selectedLLM = .groq
            cleanupEnabled = defaults.bool(forKey: "cleanupEnabled")
        }
        onboardingComplete = defaults.bool(forKey: "onboardingComplete")
        let accessMode: AppAccessMode
        if let savedAccessMode = defaults.string(forKey: "accessMode").flatMap(AppAccessMode.init(rawValue:)) {
            accessMode = savedAccessMode
        } else {
            accessMode = onboardingComplete ? .systemWide : .leastPrivileges
            defaults.set(accessMode.rawValue, forKey: "accessMode")
        }
        selectedStyleID = defaults.string(forKey: "selectedStyleID").flatMap(UUID.init(uuidString:))
        cleanupCustomInstruction = String((defaults.string(forKey: "cleanupCustomInstruction") ?? "").prefix(Self.maximumCleanupInstructionLength))
        let systemWideInsertionMode = InsertionMode(
            rawValue: defaults.string(forKey: "insertionMode") ?? ""
        ) ?? .insert
        accessConfiguration = AppAccessConfiguration(
            mode: accessMode,
            systemWideInsertionMode: systemWideInsertionMode
        )
        dictateShortcut = loadShortcut(forKey: "shortcut.dictate", fallback: .dictate)
        dictateActivationMode = HotkeyActivationMode(
            rawValue: defaults.string(forKey: "dictateActivationMode") ?? ""
        ) ?? .hold
        pasteLatestShortcut = loadShortcut(forKey: "shortcut.pasteLatest", fallback: .pasteLatest)
        defaults.set(selectedSTT.rawValue, forKey: "selectedSTT")
        if selectedSTT != .appleSpeech { defaults.set(selectedSTT.rawValue, forKey: "lastCloudSTT") }
        configureHotkeys()
        recorder.onLevel = { [weak self] level in
            Task { @MainActor in self?.hud.model.push(level: level) }
        }
        hud.onStop = { [weak self] in
            Task { @MainActor in await self?.stopDictation() }
        }
        hotkeys.onPress = { [weak self] targetPID in
            Task { @MainActor in await self?.handleDictatePress(targetProcessIdentifier: targetPID) }
        }
        hotkeys.onRelease = { [weak self] in Task { @MainActor in await self?.stopDictation() } }
        hotkeys.onPasteLatest = { [weak self] in Task { @MainActor in await self?.pasteClipboard() } }
        hotkeys.onWillSleep = { [weak self] in
            guard let self, phase == .listening else { return }
            cancelDictation()
        }
        hotkeys.onDidWake = { [weak self] in
            guard let self else { return }
            if phase == .listening {
                cancelDictation()
            } else {
                recorder.cancel()
            }
        }
        hotkeys.onStateChange = { [weak self] state in self?.applyHotkeyState(state) }
        if !runningTests {
            if accessMode.allowsGlobalShortcuts {
                if onboardingComplete { requestRequiredPermissions() }
            }
            reconcileHotkeyLifecycle()
        }
        if runningTests {
            didCompleteInitialLoad = true
        } else {
            initialLoadTask = Task { @MainActor [weak self] in
                await self?.load()
            }
        }
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            // Defer panel layout until SwiftUI has finished installing this @State model.
            // Resizing an NSHostingView during AttributeGraph construction aborts on macOS 26.
            hud.show(.idle)
            if !runningTests {
                await waitForInitialLoad()
                if selectedSTT == .appleSpeech { await appleSpeech.refresh() }
            }
        }
    }

    func setAccessMode(_ mode: AppAccessMode) {
        guard mode != accessMode else { return }
        if phase == .listening { cancelDictation() }
        accessConfiguration = accessConfiguration.selectingAccessMode(mode)
        defaults.set(mode.rawValue, forKey: "accessMode")
        reconcileHotkeyLifecycle()
    }

    private static func defaultAppleSpeechProvider() -> (any LocalSpeechTranscribing)? {
        if #available(macOS 26.0, *) { return AppleSpeechTranscriber() }
        return nil
    }

    /// In toggle mode the same press both starts and stops, so route it against
    /// the live phase rather than tracking a separate armed flag in the event tap.
    private func handleDictatePress(targetProcessIdentifier: pid_t?) async {
        if dictateActivationMode == .toggle, phase == .listening {
            await stopDictation()
            return
        }
        await startDictation(targetProcessIdentifier: targetProcessIdentifier)
    }

    func startDictation(targetProcessIdentifier: pid_t? = nil, forceClipboardDelivery: Bool = false) async {
        await waitForInitialLoad()
        guard phase == .idle else { return }
        guard await recorder.requestPermission() else {
            showError("Microphone permission is required")
            return
        }
        // The captured target is only needed once insertion happens, so defer
        // the Accessibility walk until after recording has actually started
        // instead of making the user wait through it before hearing feedback.
        // A placeholder delivery keeps `activeRun` non-nil in case the hotkey
        // is released while `recorder.start()` is still in flight.
        let runID = UUID()
        activeRun = .standard(.focusedTarget(nil))
        activeRunID = runID
        phase = .listening
        hud.show(.listening)
        await Task.yield()
        guard phase == .listening, activeRunID == runID else { return }
        do {
            warmUpConnections()
            try await recorder.start()
        } catch {
            guard activeRunID == runID else { return }
            activeRun = nil
            activeRunID = nil
            phase = .idle
            showError(error.localizedDescription)
            return
        }
        guard activeRunID == runID else { return }
        guard insertionMode != .clipboard, !forceClipboardDelivery else {
            activeRun = .standard(.clipboard)
            return
        }
        // A blocked target (e.g. a secure field) still records; the inserter
        // then keeps the text off the system pasteboard (`.privateClipboard`)
        // so it is only reachable through the transcript history / paste-latest.
        let target = inserter.captureFocusedTarget(processIdentifier: targetProcessIdentifier)
        activeRun = .standard(.focusedTarget(target))
    }

    /// Opens the STT and cleanup providers' HTTPS connections while the user
    /// is still speaking so the DNS/TCP/TLS handshakes overlap recording
    /// instead of adding to post-dictation latency.
    private func warmUpConnections() {
        let cleanup = try? cleanupConfiguration()
        Task(priority: .userInitiated) { [transcriptionCoordinator, selectedSTT] in
            async let sttWarmUp: Void = transcriptionCoordinator.warmUp(selectedProvider: selectedSTT)
            if let cleanup {
                async let cleanupWarmUp: Void = cleanup.provider.warmUpConnection(credentials: cleanup.credentials)
                _ = await (sttWarmUp, cleanupWarmUp)
            } else {
                await sttWarmUp
            }
        }
    }

    func stopDictation() async {
        guard phase == .listening else { return }
        guard let run = activeRun else {
            showError("The active dictation session was lost.")
            return
        }
        phase = .processing
        activeRun = nil
        activeRunID = nil
        let pipelineStarted = ContinuousClock.now
        let audio = await recorder.stop()
        guard audio.duration >= 0.15 else {
            phase = .idle
            let usesToggle = dictateActivationMode == .toggle
            hud.show(.error(usesToggle
                ? "Too short—speak, then press \(dictateShortcut.displayName)"
                : "Too short—hold \(dictateShortcut.displayName) while speaking"))
            hud.hideAfterDelay()
            return
        }
        switch run {
        case .standard(let delivery):
            await process(audio, delivery: delivery, pipelineStarted: pipelineStarted)
        }
    }

    func cancelDictation() {
        guard phase == .listening else { return }
        activeRun = nil
        activeRunID = nil
        phase = .idle
        recorder.cancel()
        hud.show(.success(.cancelled))
        hud.hideAfterDelay()
    }

    private func process(
        _ audio: RecordedAudio,
        delivery: StandardDictationDelivery,
        pipelineStarted: ContinuousClock.Instant
    ) async {
        hud.show(.transcribing)
        do {
            let target = delivery.target
            let transcription = try await transcriptionCoordinator.transcribe(
                audio: audio,
                selectedProvider: selectedSTT,
                selectedModel: configuredModel(for: .speechToText, provider: selectedSTT),
                vocabulary: data.vocabulary
            )
            let cleanup = transcription.allowsCleanup ? try cleanupConfiguration() : nil
            if cleanup != nil { hud.show(.cleaning) }
            let processed = await transcriptProcessor.process(
                rawText: transcription.result.text,
                selectedText: target?.selection?.text,
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

            // Clipboard delivery never touches the target selection, so a
            // transformation intent degrades to copying the transformed text.
            guard let insertion = requestedInsertion(
                text: finalText,
                replacesSelection: target != nil && cleanupResult?.intent == .transformation,
                target: target
            ) else { return }
            await completeDictation(
                audio: audio,
                transcription: transcription,
                finalText: finalText,
                insertion: insertion,
                delivery: delivery,
                llmExecution: cleanupResult.map(LLMExecution.init(result:)),
                cleanupFallbackReason: cleanupFallbackReason,
                pipelineStarted: pipelineStarted
            )
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func requestedInsertion(
        text: String,
        replacesSelection: Bool,
        target: FocusedTarget?
    ) -> TextInsertion? {
        guard replacesSelection else { return .dictation(text) }
        guard let selection = target?.selection else {
            showError("The selected text is no longer available")
            return nil
        }
        return .transformation(text, expectedSelection: selection)
    }

    private func completeDictation(
        audio: RecordedAudio,
        transcription: TranscriptionRun,
        finalText: String,
        insertion: TextInsertion,
        delivery: StandardDictationDelivery,
        llmExecution: LLMExecution?,
        cleanupFallbackReason: String?,
        pipelineStarted: ContinuousClock.Instant
    ) async {
        let target = delivery.target
        let outcome: InsertionResult
        switch delivery {
        case .clipboard:
            outcome = clipboardWriter.write(finalText)
                ? .copiedToClipboard
                : .privateClipboard("the system clipboard could not be updated")
        case .focusedTarget(let target):
            outcome = await inserter.insert(insertion, into: target)
        }
        showCompletion(
            insertion: outcome,
            cleanupFallbackReason: cleanupFallbackReason,
            usedAppleFallback: transcription.usedAppleFallback
        )
        let transcript = TranscriptRecord(
            rawText: transcription.result.text,
            finalText: finalText,
            sttProvider: transcription.result.provider,
            sttModel: transcription.result.model,
            sttLocale: transcription.result.language,
            sourceBundleID: target?.bundleIdentifier,
            audioDuration: audio.duration,
            sttLatency: transcription.result.latency,
            pipelineLatency: seconds(since: pipelineStarted),
            llmExecution: llmExecution,
            insertionOutcome: outcome.label
        )
        data.lifetimeStatistics.record(transcript)
        data.transcripts.insert(transcript, at: 0)
        phase = .idle
        hud.hideAfterDelay()
        schedulePersistence()
    }

    func credentials(purpose: ProviderPurpose, provider: ProviderKind) -> ProviderCredentials? {
        try? resolvedCredentials(purpose: purpose, provider: provider)
    }

    func isProviderConfigured(purpose: ProviderPurpose, provider: ProviderKind) -> Bool {
        credentials(purpose: purpose, provider: provider)?.apiKey.isEmpty == false
    }

    func saveCredentials(_ credentials: ProviderCredentials, purpose: ProviderPurpose, provider: ProviderKind, model: String) throws {
        guard provider != .appleSpeech else {
            throw ProviderError.invalidConfiguration("Apple On-Device transcription does not use API credentials.")
        }
        guard !credentials.apiKey.isEmpty else { throw ProviderError.missingCredential("API key") }
        guard !model.isEmpty else { throw ProviderError.invalidConfiguration("Enter a model name.") }
        try keychain.save(credentials, for: purpose, provider: provider)
        defaults.set(model, forKey: modelKey(for: purpose, provider: provider))
        credentialCache.removeAll()
    }

    func testProviderConnection(
        purpose: ProviderPurpose,
        provider: ProviderKind,
        model: String,
        credentials: ProviderCredentials
    ) async throws {
        try await providerConnections.test(
            purpose: purpose,
            provider: provider,
            model: model,
            credentials: credentials
        )
    }

    func selectSTT(_ provider: ProviderKind) throws {
        guard provider != selectedSTT else { return }
        let lastCloud = try STTProviderSelection.prepareTransition(
            from: selectedSTT,
            to: provider,
            selectedCleanup: selectedLLM,
            store: keychain
        )
        if let lastCloud { defaults.set(lastCloud.rawValue, forKey: "lastCloudSTT") }
        // The cleanup credential lookup falls back to the STT key when the
        // provider matches `selectedSTT`, so a cache entry computed under
        // the old selection can go stale the moment it changes.
        credentialCache.removeAll()
        selectedSTT = provider
        defaults.set(provider.rawValue, forKey: "selectedSTT")
        if provider == .appleSpeech, !appleSpeech.state.readiness.isReady {
            Task { await appleSpeech.refresh() }
        }
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

    func insertVocabulary(_ entry: VocabularyEntry, at index: Int) {
        data.vocabulary.insert(entry, at: min(max(index, 0), data.vocabulary.count))
        schedulePersistence()
    }

    /// Deletes immediately and registers the reinsertion as an undo action, so the
    /// row disappears without a confirmation prompt but can be brought back with
    /// Cmd+Z. Factored out of the view so the undo wiring is unit-testable.
    func deleteVocabularyWithUndo(_ id: UUID, undoManager: UndoManager?) {
        guard let index = data.vocabulary.firstIndex(where: { $0.id == id }) else { return }
        let entry = data.vocabulary[index]
        deleteVocabulary(id)
        undoManager?.registerUndo(withTarget: self) { $0.insertVocabulary(entry, at: index) }
        undoManager?.setActionName("Delete Vocabulary Entry")
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

    func insertStyle(_ style: WritingStyle, at index: Int) {
        data.styles.insert(style, at: min(max(index, 0), data.styles.count))
        schedulePersistence()
    }

    /// See `deleteVocabularyWithUndo` for why this lives on the model rather than
    /// inline in the view.
    func deleteStyleWithUndo(_ id: UUID, undoManager: UndoManager?) {
        guard let index = data.styles.firstIndex(where: { $0.id == id }) else { return }
        let style = data.styles[index]
        deleteStyle(id)
        undoManager?.registerUndo(withTarget: self) { $0.insertStyle(style, at: index) }
        undoManager?.setActionName("Delete Style")
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

    func insertSnippet(_ snippet: SnippetEntry, at index: Int) {
        data.snippets.insert(snippet, at: min(max(index, 0), data.snippets.count))
        schedulePersistence()
    }

    /// See `deleteVocabularyWithUndo` for why this lives on the model rather than
    /// inline in the view.
    func deleteSnippetWithUndo(_ id: UUID, undoManager: UndoManager?) {
        guard let index = data.snippets.firstIndex(where: { $0.id == id }) else { return }
        let snippet = data.snippets[index]
        deleteSnippet(id)
        undoManager?.registerUndo(withTarget: self) { $0.insertSnippet(snippet, at: index) }
        undoManager?.setActionName("Delete Snippet")
    }

    func pasteClipboard() async {
        guard let text = data.transcripts.first?.finalText else { return }
        if insertionMode == .clipboard {
            if clipboardWriter.write(text) {
                hud.show(.success(.copied))
                hud.hideAfterDelay()
            } else {
                showError("Could not update the system clipboard")
            }
            return
        }
        if await inserter.pasteIntoFrontmostApp(text) {
            hud.show(.success(.pasteSent))
            hud.hideAfterDelay()
        } else {
            showError("Could not post the paste shortcut")
        }
    }

    func copyTranscriptText(_ text: String) {
        if !clipboardWriter.write(text) { showError("Could not update the system clipboard") }
    }

    func pasteTranscriptText(_ text: String) async {
        if insertionMode == .clipboard {
            if !clipboardWriter.write(text) { showError("Could not update the system clipboard") }
            return
        }
        if !(await inserter.pasteIntoFrontmostApp(text)) { showError("Could not post the paste shortcut") }
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

    func setInsertionMode(_ mode: InsertionMode) {
        guard accessMode.allowsFocusedInsertion else { return }
        guard mode != insertionMode else { return }
        accessConfiguration = accessConfiguration.selectingSystemWideInsertionMode(mode)
        defaults.set(mode.rawValue, forKey: "insertionMode")
    }

    func requestAccessibilityPermission() {
        guard accessMode.allowsGlobalShortcuts else { return }
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    func requestInputMonitoringPermission() {
        guard accessMode.allowsGlobalShortcuts else { return }
        _ = CGRequestListenEventAccess()
        hotkeys.start()
    }

    func requestMicrophonePermission() async {
        microphoneGranted = await recorder.requestPermission()
    }

    @discardableResult
    func setShortcut(_ shortcut: GlobalShortcut, for purpose: ShortcutPurpose) -> Bool {
        let others: [GlobalShortcut]
        switch purpose {
        case .dictate: others = [pasteLatestShortcut]
        case .pasteLatest: others = [dictateShortcut]
        }
        guard !others.contains(shortcut) else { return false }

        switch purpose {
        case .dictate: dictateShortcut = shortcut
        case .pasteLatest: pasteLatestShortcut = shortcut
        }
        persistShortcuts()
        configureHotkeys()
        return true
    }

    var dictateInstruction: String {
        switch dictateActivationMode {
        case .hold: "Hold \(dictateShortcut.displayName) to dictate"
        case .toggle: "Press \(dictateShortcut.displayName) to start and stop"
        }
    }

    func setDictateActivationMode(_ mode: HotkeyActivationMode) {
        guard mode != dictateActivationMode else { return }
        // The in-flight recording was started under the old mode and its stop
        // edge would never arrive, so end it before switching.
        if phase == .listening { cancelDictation() }
        dictateActivationMode = mode
        defaults.set(mode.rawValue, forKey: "dictateActivationMode")
        configureHotkeys()
    }

    func resetShortcuts() {
        dictateShortcut = .dictate
        pasteLatestShortcut = .pasteLatest
        persistShortcuts()
        configureHotkeys()
    }

    func requestOnboardingPermissions() async {
        if accessMode.allowsGlobalShortcuts {
            requestAccessibilityPermission()
            requestInputMonitoringPermission()
        } else {
            hotkeys.stop()
        }
        await requestMicrophonePermission()
        refreshPermissionState()
    }

    func refreshPermissionState() {
        accessibilityGranted = AXIsProcessTrusted()
        inputMonitoringGranted = CGPreflightListenEventAccess()
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if accessMode.allowsGlobalShortcuts {
            hotkeys.retry()
        } else {
            hotkeys.stop()
        }
    }

    var onboardingPermissionsReady: Bool {
        guard microphoneGranted else { return false }
        guard accessMode.allowsGlobalShortcuts else { return true }
        return accessibilityGranted && inputMonitoringGranted && shortcutsAvailable
    }

    func selectAppleSpeechLocale(_ identifier: String) {
        guard identifier != appleSpeech.state.selectedLocaleIdentifier else { return }
        appleSpeech.selectLocale(identifier)
    }

    func finishOnboarding() {
        onboardingComplete = true
        defaults.set(true, forKey: "onboardingComplete")
        reconcileHotkeyLifecycle()
    }

    func setCleanupCustomInstruction(_ instruction: String) {
        let bounded = String(instruction.prefix(Self.maximumCleanupInstructionLength))
        cleanupCustomInstruction = bounded
        defaults.set(bounded, forKey: "cleanupCustomInstruction")
    }

    var selectedSTTIsConfigured: Bool {
        selectedSTT == .appleSpeech
            ? appleSpeech.state.readiness.isReady
            : credentials(purpose: .speechToText, provider: selectedSTT)?.apiKey.isEmpty == false
    }

    var appleSpeechAvailable: Bool { appleSpeech.isAvailable }

    var sttMetadata: [ProviderMetadata] {
        ProviderRegistry.sttMetadata(includeAppleSpeech: appleSpeechAvailable)
    }

    func configuredModel(for purpose: ProviderPurpose, provider: ProviderKind) -> String? {
        defaults.string(forKey: modelKey(for: purpose, provider: provider))
    }

    private func modelKey(for purpose: ProviderPurpose, provider: ProviderKind) -> String {
        "\(purpose.rawValue)Model.\(provider.rawValue)"
    }

    private func resolvedCredentials(purpose: ProviderPurpose, provider: ProviderKind) throws -> ProviderCredentials? {
        let key = "\(purpose.rawValue):\(provider.rawValue)"
        if let cached = credentialCache[key] { return cached }
        let resolved = try loadCredentials(purpose: purpose, provider: provider)
        credentialCache[key] = resolved
        return resolved
    }

    private func loadCredentials(purpose: ProviderPurpose, provider: ProviderKind) throws -> ProviderCredentials? {
        if let saved = try keychain.load(for: purpose, provider: provider) { return saved }
        switch purpose {
        case .speechToText:
            return nil
        case .cleanup:
            guard provider == selectedSTT else { return nil }
            return try keychain.load(for: .speechToText, provider: provider)
        }
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
        let style = StyleResolver.instruction(
            styles: data.styles,
            globalStyleID: selectedStyleID
        )
        let custom = cleanupCustomInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptCleanupConfiguration(
            provider: provider,
            model: model,
            credentials: credentials,
            styleInstruction: style,
            customInstruction: custom.isEmpty ? nil : custom
        )
    }

    private func showCompletion(
        insertion: InsertionResult,
        cleanupFallbackReason: String?,
        usedAppleFallback: Bool = false
    ) {
        if let cleanupFallbackReason {
            lastError = "Cleanup failed: \(cleanupFallbackReason)"
            hud.show(.warning("Cleanup failed—used raw transcript"))
            return
        }
        lastError = nil
        if usedAppleFallback {
            switch insertion {
            case .privateClipboard: hud.show(.clipboard(shortcut: pasteLatestShortcutDisplay))
            case .copiedToClipboard: hud.show(.success(.copiedViaAppleFallback))
            case .pasteCommandPosted: hud.show(.success(.pasteSentViaAppleFallback))
            }
            return
        }
        switch insertion {
        case .privateClipboard: hud.show(.clipboard(shortcut: pasteLatestShortcutDisplay))
        case .copiedToClipboard: hud.show(.success(.copied))
        case .pasteCommandPosted: hud.show(.success(.pasteSent))
        }
    }

    /// `pasteLatestShortcut` is a global hotkey that only functions with Input
    /// Monitoring permission, which least-privilege mode never requests. The
    /// HUD hint there points to the plain system ⌘V paste instead, since the
    /// transcript is on the system clipboard in that mode.
    private var pasteLatestShortcutDisplay: String {
        accessMode == .leastPrivileges ? "⌘V" : pasteLatestShortcut.displayName
    }

    private func requestRequiredPermissions() {
        guard accessMode.allowsGlobalShortcuts else { return }
        // Clipboard delivery works without Accessibility, so the user who
        // chose it is not re-prompted on every launch.
        if insertionMode == .insert, !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
    }

    private func reconcileHotkeyLifecycle() {
        if accessMode.allowsGlobalShortcuts, onboardingComplete {
            hotkeys.start()
        } else {
            hotkeys.stop()
        }
    }

    private func applyHotkeyState(_ state: HotkeyLifecycleState) {
        switch state {
        case .stopped:
            shortcutsAvailable = false
        case .available:
            shortcutsAvailable = true
            accessibilityGranted = AXIsProcessTrusted()
            inputMonitoringGranted = CGPreflightListenEventAccess()
            if lastError == HotkeyError.permissionRequired.localizedDescription { lastError = nil }
        case let .unavailable(message):
            shortcutsAvailable = false
            lastError = message
        }
    }

    private func configureHotkeys() {
        hotkeys.configure(
            dictate: dictateShortcut,
            dictateActivation: dictateActivationMode,
            pasteLatest: pasteLatestShortcut
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
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { lastError = error.localizedDescription }
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func load() async {
        do {
            data = try await store.load()
            if let selectedStyleID, !data.styles.contains(where: { $0.id == selectedStyleID && $0.isEnabled }) { self.selectedStyleID = nil }
            didCompleteInitialLoad = true
        } catch { lastError = error.localizedDescription }
    }

    private func waitForInitialLoad() async {
        await initialLoadTask?.value
        initialLoadTask = nil
    }

    @ObservationIgnored private var pendingPersistTask: Task<Void, Never>?
    @ObservationIgnored private(set) var persistCount = 0

    /// Coalesces bursts of edits (vocabulary, styles, snippets, transcripts)
    /// into a single write instead of spawning a task per call.
    private func schedulePersistence() {
        pendingPersistTask?.cancel()
        pendingPersistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            await self.persist()
            self.pendingPersistTask = nil
        }
    }

    /// Persists immediately, skipping any pending debounce window. Used on
    /// app termination so the last edit isn't lost mid-debounce. Guarded so
    /// a termination that races (or precedes) the initial load can't
    /// overwrite `data.json` with an incomplete or default in-memory
    /// snapshot when nothing was actually pending to save.
    func flushPersistence() async {
        guard pendingPersistTask != nil, didCompleteInitialLoad else { return }
        pendingPersistTask?.cancel()
        pendingPersistTask = nil
        await persist()
    }

    private func persist() async {
        let snapshot = data
        do {
            try await store.save(snapshot)
            persistCount += 1
        } catch { lastError = "Could not save local data: \(error.localizedDescription)" }
    }

    private func showError(_ message: String) {
        lastError = message
        phase = .idle
        hud.show(.error(message))
        hud.hideAfterDelay()
    }
}
