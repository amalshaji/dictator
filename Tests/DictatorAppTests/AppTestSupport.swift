import DictatorCore
import Foundation
@testable import Dictator

struct AppTestCredentialStore: CredentialStoring {
    func save(_ credentials: ProviderCredentials, for purpose: ProviderPurpose, provider: ProviderKind) throws {}
    func load(for purpose: ProviderPurpose, provider: ProviderKind) throws -> ProviderCredentials? { nil }
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

struct AppTestConnectivityMonitor: ConnectivityMonitoring {
    let state: ConnectivityState = .online
}
