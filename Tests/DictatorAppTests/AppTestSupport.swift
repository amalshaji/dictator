import ApplicationServices
import AppKit
import AVFoundation
import DictatorCore
import Foundation
@testable import Dictator

struct AppTestCredentialStore: CredentialStoring {
    func save(_ credentials: ProviderCredentials, for purpose: ProviderPurpose, provider: ProviderKind) throws {}
    func load(for purpose: ProviderPurpose, provider: ProviderKind) throws -> ProviderCredentials? { nil }
}
struct ConfiguredProviderCredentialStore: CredentialStoring {
    func save(_ credentials: ProviderCredentials, for purpose: ProviderPurpose, provider: ProviderKind) throws {}

    func load(for purpose: ProviderPurpose, provider: ProviderKind) throws -> ProviderCredentials? {
        guard case .cleanup = purpose, provider == .groq else { return nil }
        return ProviderCredentials(apiKey: "test-key")
    }
}

struct SpeechOnlyGroqCredentialStore: CredentialStoring {
    func save(_ credentials: ProviderCredentials, for purpose: ProviderPurpose, provider: ProviderKind) throws {}

    func load(for purpose: ProviderPurpose, provider: ProviderKind) throws -> ProviderCredentials? {
        guard purpose == .speechToText, provider == .groq else { return nil }
        return ProviderCredentials(apiKey: "shared-key")
    }
}

@MainActor
final class TestAudioRecorder: AudioRecording {
    var onLevel: (@Sendable (Double) -> Void)?
    var onStart: (() -> Void)?
    var startError: Error?
    var startGate: AudioStartGate?
    var recordedAudio = RecordedAudio(wavData: Data(), duration: 0)
    private(set) var cancelCount = 0
    private(set) var permissionRequestCount = 0

    func requestPermission() async -> Bool {
        permissionRequestCount += 1
        return true
    }
    func start() async throws {
        onStart?()
        await startGate?.waitUntilRelease()
        if let startError { throw startError }
    }
    func stop() async -> RecordedAudio { recordedAudio }
    func cancel() { cancelCount += 1 }
}

final class AudioStartGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var released = false
    private var respondedBeforeRelease = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    var mainActorRespondedBeforeRelease: Bool {
        condition.withLock { respondedBeforeRelease }
    }

    func waitUntilRelease() async {
        await withCheckedContinuation { continuation in
            var shouldResume = false
            condition.lock()
            started = true
            condition.broadcast()
            if released {
                shouldResume = true
            } else {
                releaseContinuation = continuation
            }
            condition.unlock()
            if shouldResume { continuation.resume() }
        }
    }

    func waitUntilStarted() {
        condition.lock()
        while !started { condition.wait() }
        condition.unlock()
    }

    func recordMainActorResponse() {
        condition.withLock { respondedBeforeRelease = !released }
    }

    func release() {
        let continuation: CheckedContinuation<Void, Never>?
        condition.lock()
        released = true
        continuation = releaseContinuation
        releaseContinuation = nil
        condition.broadcast()
        condition.unlock()
        continuation?.resume()
    }
}

final class TestAudioCaptureSession: AudioCaptureSession, @unchecked Sendable {
    let recoveryNotification = Notification.Name("TestAudioCaptureSessionRecovery")
    private(set) var recoverySourceObject = TestAudioConfigurationSource()
    var recoverySourceIdentifier: ObjectIdentifier? {
        ObjectIdentifier(recoverySourceObject)
    }
    var onStart: (() -> Void)?
    var firstStartGate: AudioStartGate?
    var stopGate: AudioStartGate?
    var startFailuresRemaining = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var tapHandler: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?

    func start(
        tapHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) async throws {
        startCount += 1
        self.tapHandler = tapHandler
        recoverySourceObject = TestAudioConfigurationSource()
        let shouldFail = startFailuresRemaining > 0
        if shouldFail {
            startFailuresRemaining -= 1
        }
        if startCount == 1 {
            await firstStartGate?.waitUntilRelease()
        }
        if shouldFail {
            throw AudioRecorderError.noInput
        }
        onStart?()
    }

    func stop() async {
        stopCount += 1
        recoverySourceObject = TestAudioConfigurationSource()
        guard let stopGate, let tapHandler else { return }
        await stopGate.waitUntilRelease()
        guard let pcm = Self.makePendingBuffer() else { return }
        tapHandler(pcm, AVAudioTime(hostTime: 0))
    }

    func cancel() {
        stopCount += 1
        recoverySourceObject = TestAudioConfigurationSource()
    }

    func emit(_ pcm: AVAudioPCMBuffer) {
        tapHandler?(pcm, AVAudioTime(hostTime: 0))
    }

    private static func makePendingBuffer() -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600),
              let samples = pcm.floatChannelData?[0]
        else { return nil }
        pcm.frameLength = 1_600
        for index in 0..<1_600 { samples[index] = 0.1 }
        return pcm
    }
}

final class TestAudioConfigurationSource: NSObject, @unchecked Sendable {}

@MainActor
final class TestScreenContextCapture: ScreenContextCapturing {
    var permissionGranted = true
    var capturedContext: CapturedScreenContext?
    private(set) var captureCount = 0

    func requestPermission() -> Bool { true }

    func capture(_ window: FocusedWindowSnapshot) async throws -> CapturedScreenContext {
        captureCount += 1
        if let capturedContext { return capturedContext }
        throw ScreenContextCaptureError.focusedWindowUnavailable
    }
}

@MainActor
final class TestTranscriptionCoordinator: TranscriptionCoordinating {
    let result: TranscriptionRun

    init(result: TranscriptionRun) {
        self.result = result
    }

    func transcribe(
        audio: RecordedAudio,
        selectedProvider: ProviderKind,
        selectedModel: String?,
        fallbackEnabled: Bool,
        vocabulary: [VocabularyEntry],
        onModeChange: (TranscriptionMode) -> Void
    ) async throws -> TranscriptionRun {
        result
    }
}

@MainActor
final class TestTargetInserter: FocusedTargetInserting {
    let target: FocusedTarget
    let window: FocusedWindowSnapshot
    private(set) var insertedText: String?
    private(set) var pastedText: String?
    private(set) var captureCount = 0

    init(target: FocusedTarget, window: FocusedWindowSnapshot) {
        self.target = target
        self.window = window
    }

    func captureFocusedTarget(processIdentifier: pid_t?) -> FocusedTarget? {
        captureCount += 1
        return target
    }
    func captureFocusedWindow(for target: FocusedTarget) -> FocusedWindowSnapshot? { window }
    func insert(_ insertion: TextInsertion, into target: FocusedTarget?) async -> InsertionResult {
        insertedText = insertion.text
        return .pasteCommandPosted(.activeApplication)
    }
    func pasteIntoFrontmostApp(_ text: String) async -> Bool {
        pastedText = text
        return true
    }
}

@MainActor
final class TestClipboardWriter: ClipboardWriting {
    private(set) var text: String?

    func write(_ text: String) -> Bool {
        self.text = text
        return true
    }
}

struct TestScreenAwareProvider: ScreenAwareLLMProvider {
    let model: String
    var metadata: ProviderMetadata {
        ScreenAwareProviderRegistry.provider(for: .groq)!.metadata
    }

    func validate(credentials: ProviderCredentials) async throws {}
    func listModels(credentials: ProviderCredentials) async throws -> [String] { [model] }
    func generate(request: ScreenAwareRequest, model: String, credentials: ProviderCredentials) async throws -> ScreenAwareResult {
        .init(
            intent: .insert,
            text: "Hi Sam,\n\nTuesday works for me.",
            provider: .groq,
            model: model,
            inputTokens: 42,
            outputTokens: 12,
            latency: 0.2
        )
    }
}

struct ScreenAwareCredentialStore: CredentialStoring {
    func save(_ credentials: ProviderCredentials, for purpose: ProviderPurpose, provider: ProviderKind) throws {}

    func load(for purpose: ProviderPurpose, provider: ProviderKind) throws -> ProviderCredentials? {
        guard purpose == .screenAware, provider == .groq else { return nil }
        return ProviderCredentials(apiKey: "test-key")
    }
}

final class AudioLevelRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    var values: [Double] { lock.withLock { storage } }
    func append(_ value: Double) { lock.withLock { storage.append(value) } }
}

struct AppTestConnectivityMonitor: ConnectivityMonitoring {
    let state: ConnectivityState = .online
}

actor DelayedAppleSpeechProvider: LocalSpeechTranscribing {
    private let locales = [
        AppleSpeechLocale(identifier: "en_US", engine: .speechTranscriber),
        AppleSpeechLocale(identifier: "fr_FR", engine: .speechTranscriber)
    ]

    func availableLocales() async -> [AppleSpeechLocale] { locales }

    func readiness(for localeIdentifier: String) async -> AppleSpeechReadiness {
        try? await Task.sleep(for: localeIdentifier == "en_US" ? .milliseconds(100) : .milliseconds(1))
        return .ready(.init(identifier: localeIdentifier, engine: .speechTranscriber))
    }

    func installAssets(
        for localeIdentifier: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> AppleSpeechReadiness {
        .ready(.init(identifier: localeIdentifier, engine: .speechTranscriber))
    }

    func transcribe(
        audio: RecordedAudio,
        localeIdentifier: String,
        vocabulary: [VocabularyEntry]
    ) async throws -> TranscriptionResult {
        .init(
            text: "test",
            language: localeIdentifier,
            provider: .appleSpeech,
            model: AppleTranscriptionEngine.speechTranscriber.rawValue,
            latency: 0
        )
    }
}

@MainActor
final class InsertionFixture {
    let targetPID: pid_t = 4242
    let applicationElement = AXUIElementCreateApplication(4242)
    let fieldElement = AXUIElementCreateApplication(4242)
    let applicationState = TestApplicationState()
    let clipboard = TestClipboard()
    let events = TestEventRecorder()
    let originalSelection = TextSelectionSnapshot(text: "SELECTED TEXT", location: 0, length: 13)
    let application: ApplicationTarget
    let inserter: AccessibilityInserter

    init(bundleIdentifier: String = "com.example.editor") {
        application = ApplicationTarget(
            element: applicationElement,
            name: "Test App",
            bundleIdentifier: bundleIdentifier,
            processIdentifier: targetPID
        )
        applicationState.frontmostPID = targetPID
        applicationState.runningPIDs = [targetPID, 777]
        applicationState.currentSelection = originalSelection

        let state = applicationState
        let eventRecorder = events
        let environment = InsertionEnvironment(
            frontmostProcessIdentifier: { state.frontmostPID },
            isRunning: { state.runningPIDs.contains($0) },
            activate: {
                state.activatedPIDs.append($0)
                return state.activationSucceeds
            },
            focus: { _ in
                state.focusAttempts += 1
                return state.focusSucceeds
            },
            selection: { _ in state.currentSelection },
            delay: { _ in }
        )
        let paster = ClipboardPaster(
            clipboard: clipboard,
            postEvent: { eventRecorder.post($0) },
            delay: { _ in }
        )
        inserter = AccessibilityInserter(environment: environment, paster: paster)
    }
}

@MainActor
final class TestApplicationState {
    var frontmostPID: pid_t?
    var runningPIDs: Set<pid_t> = []
    var activatedPIDs: [pid_t] = []
    var activationSucceeds = true
    var focusSucceeds = true
    var focusAttempts = 0
    var currentSelection: TextSelectionSnapshot?
}

@MainActor
final class TestClipboard: ClipboardAccess {
    var ownsPreparedContents = true
    var prepareSucceeds = true
    var didRestore = false
    private var preparedText: String?
    private var preparedSessionID: String?
    var lastPreparedText: String? { preparedText }

    func snapshot() -> PasteboardSnapshot { PasteboardSnapshot(items: []) }
    func prepare(text: String, sessionID: String) -> Bool {
        preparedText = text
        preparedSessionID = sessionID
        return prepareSucceeds
    }
    func owns(text: String, sessionID: String) -> Bool {
        ownsPreparedContents && text == preparedText && sessionID == preparedSessionID
    }
    func restore(_ snapshot: PasteboardSnapshot) { didRestore = true }
}

@MainActor
final class TestEventRecorder {
    var events: [PostedKeyEvent] = []
    var failureIndex: Int?

    func post(_ event: PostedKeyEvent) -> Bool {
        let index = events.count
        events.append(event)
        return index != failureIndex
    }
}
