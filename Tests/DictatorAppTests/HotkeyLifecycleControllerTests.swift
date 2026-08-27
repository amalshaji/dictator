import AppKit
import Combine
import DictatorCore
import Foundation
import XCTest
@testable import Dictator

@MainActor
final class HotkeyLifecycleControllerTests: XCTestCase {
    func testStopPreventsWakeFromRestartingHotkeys() {
        let notifications = NotificationCenter()
        let hotkey = TestHotkeyMonitor(isRunning: false)
        let controller = HotkeyLifecycleController(
            monitor: hotkey,
            notificationCenter: notifications
        )
        controller.start()
        XCTAssertEqual(hotkey.startCount, 1)

        controller.stop()
        notifications.post(
            name: NSWorkspace.didWakeNotification,
            object: NSWorkspace.shared
        )

        XCTAssertEqual(hotkey.startCount, 1)
        XCTAssertFalse(hotkey.isRunning)
        XCTAssertEqual(controller.state, .stopped)
    }

    func testLeastPrivilegesPermissionRequestStartsNoHotkeyMonitor() async throws {
        let hotkey = TestHotkeyMonitor(isRunning: false)
        let controller = HotkeyLifecycleController(
            monitor: hotkey,
            notificationCenter: NotificationCenter()
        )
        let recorder = LifecycleAudioRecorder()
        let (model, defaults, suiteName) = try makeModel(
            hotkeys: controller,
            recorder: recorder
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }

        await model.requestOnboardingPermissions()

        XCTAssertEqual(recorder.permissionRequestCount, 1)
        XCTAssertEqual(hotkey.startCount, 0)
        XCTAssertEqual(controller.state, .stopped)
    }

    func testSwitchingFromLeastPrivilegesToSystemWideRestartsHotkeysAfterOnboarding() throws {
        let hotkey = TestHotkeyMonitor(isRunning: false)
        let controller = HotkeyLifecycleController(
            monitor: hotkey,
            notificationCenter: NotificationCenter()
        )
        let (model, defaults, suiteName) = try makeModel(
            hotkeys: controller,
            recorder: LifecycleAudioRecorder()
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }

        model.finishOnboarding()
        XCTAssertEqual(controller.state, .stopped)
        XCTAssertEqual(hotkey.startCount, 0)

        model.setAccessMode(.systemWide)

        XCTAssertEqual(hotkey.startCount, 1)
        XCTAssertEqual(controller.state, .available)
    }

    func testMicrophonePermissionRequestDoesNotStartSystemWideHotkeys() async throws {
        let hotkey = TestHotkeyMonitor(isRunning: false)
        let controller = HotkeyLifecycleController(
            monitor: hotkey,
            notificationCenter: NotificationCenter()
        )
        let recorder = LifecycleAudioRecorder()
        let (model, defaults, suiteName) = try makeModel(
            hotkeys: controller,
            recorder: recorder
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        model.setAccessMode(.systemWide)

        await model.requestMicrophonePermission()

        XCTAssertEqual(recorder.permissionRequestCount, 1)
        XCTAssertEqual(hotkey.startCount, 0)
        XCTAssertEqual(controller.state, .stopped)
    }

    func testEachWakeRecreatesHotkeyMonitorEvenWhenItReportsRunning() {
        let notifications = NotificationCenter()
        let hotkey = TestHotkeyMonitor(isRunning: true)
        let controller = HotkeyLifecycleController(
            monitor: hotkey,
            notificationCenter: notifications
        )
        controller.start()

        for _ in 0..<2 {
            notifications.post(
                name: NSWorkspace.didWakeNotification,
                object: NSWorkspace.shared
            )
        }

        XCTAssertEqual(hotkey.stopCount, 2)
        XCTAssertEqual(hotkey.startCount, 2)
        XCTAssertEqual(controller.state, .available)
    }

    func testSleepStopsHotkeysAndCancelsActiveDictationBeforeNotificationReturns() throws {
        let notifications = NotificationCenter()
        let hotkey = TestHotkeyMonitor(isRunning: true)
        let controller = HotkeyLifecycleController(
            monitor: hotkey,
            notificationCenter: notifications
        )
        let recorder = LifecycleAudioRecorder()
        let (model, defaults, suiteName) = try makeModel(
            hotkeys: controller,
            recorder: recorder
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        model.phase = .listening

        notifications.post(
            name: NSWorkspace.willSleepNotification,
            object: NSWorkspace.shared
        )

        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(recorder.cancelCount, 1)
        XCTAssertEqual(hotkey.stopCount, 1)
        XCTAssertFalse(model.shortcutsAvailable)
    }

    func testWakeResetsAudioRecorderWhenNoDictationIsActive() throws {
        let notifications = NotificationCenter()
        let hotkey = TestHotkeyMonitor(isRunning: true)
        let controller = HotkeyLifecycleController(
            monitor: hotkey,
            notificationCenter: notifications
        )
        let recorder = LifecycleAudioRecorder()
        let (model, defaults, suiteName) = try makeModel(
            hotkeys: controller,
            recorder: recorder
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        controller.start()
        XCTAssertEqual(model.phase, .idle)

        notifications.post(
            name: NSWorkspace.didWakeNotification,
            object: NSWorkspace.shared
        )

        XCTAssertEqual(recorder.cancelCount, 1)
        XCTAssertEqual(controller.state, .available)
    }

    func testRepeatedSleepWakeCyclesResetHeldStateAndPreserveAllCallbacks() {
        let notifications = NotificationCenter()
        let hotkey = TestHotkeyMonitor(
            isRunning: true,
            dictateIsDown: true
        )
        let controller = HotkeyLifecycleController(
            monitor: hotkey,
            notificationCenter: notifications
        )
        controller.start()
        var pasteCount = 0
        var clipboardCount = 0
        controller.onPasteLatest = { pasteCount += 1 }
        controller.onOpenClipboard = { clipboardCount += 1 }

        for _ in 0..<2 {
            notifications.post(
                name: NSWorkspace.willSleepNotification,
                object: NSWorkspace.shared
            )
            XCTAssertFalse(hotkey.dictateIsDown)
            notifications.post(
                name: NSWorkspace.didWakeNotification,
                object: NSWorkspace.shared
            )
        }
        hotkey.onPasteLatest?()
        hotkey.onOpenClipboard?()

        XCTAssertEqual(hotkey.stopCount, 4)
        XCTAssertEqual(hotkey.startCount, 2)
        XCTAssertEqual(pasteCount, 1)
        XCTAssertEqual(clipboardCount, 1)
        XCTAssertEqual(controller.state, .available)
    }

    func testWakeRetriesAfterTransientFailureWithOnePendingRecovery() {
        let notifications = NotificationCenter()
        let hotkey = TestHotkeyMonitor(
            isRunning: true,
            startFailuresRemaining: 2
        )
        let scheduler = ManualHotkeyRecoveryScheduler()
        let controller = HotkeyLifecycleController(
            monitor: hotkey,
            notificationCenter: notifications,
            scheduleRecovery: scheduler.schedule
        )
        controller.start()

        notifications.post(
            name: NSWorkspace.didWakeNotification,
            object: NSWorkspace.shared
        )
        notifications.post(
            name: NSWorkspace.didWakeNotification,
            object: NSWorkspace.shared
        )

        XCTAssertEqual(hotkey.startCount, 2)
        XCTAssertEqual(scheduler.scheduleCount, 2)
        XCTAssertEqual(scheduler.pendingCount, 1)
        XCTAssertEqual(
            controller.state,
            .unavailable(HotkeyError.permissionRequired.localizedDescription)
        )

        scheduler.fire()

        XCTAssertEqual(hotkey.startCount, 3)
        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertEqual(controller.state, .available)
    }

    func testToggleActivationStartsThenStopsDictationOnRepeatedPresses() async throws {
        let hotkey = TestHotkeyMonitor(isRunning: true)
        let controller = HotkeyLifecycleController(
            monitor: hotkey,
            notificationCenter: NotificationCenter()
        )
        let (model, defaults, suiteName) = try makeModel(
            hotkeys: controller,
            recorder: LifecycleAudioRecorder()
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        model.setDictateActivationMode(.toggle)
        XCTAssertEqual(defaults.string(forKey: "dictateActivationMode"), "toggle")

        hotkey.onPress?(nil)
        try await waitForPhase(.listening, on: model)

        hotkey.onPress?(nil)
        try await waitForPhase(.idle, on: model)
    }

    func testHoldActivationIgnoresARepeatedPressAndStopsOnRelease() async throws {
        let hotkey = TestHotkeyMonitor(isRunning: true)
        let controller = HotkeyLifecycleController(
            monitor: hotkey,
            notificationCenter: NotificationCenter()
        )
        let (model, defaults, suiteName) = try makeModel(
            hotkeys: controller,
            recorder: LifecycleAudioRecorder()
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertEqual(model.dictateActivationMode, .hold)

        hotkey.onPress?(nil)
        try await waitForPhase(.listening, on: model)
        hotkey.onPress?(nil)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.phase, .listening)

        hotkey.onRelease?()
        try await waitForPhase(.idle, on: model)
    }

    func testSwitchingActivationModeEndsAnInFlightDictation() throws {
        let hotkey = TestHotkeyMonitor(isRunning: true)
        let controller = HotkeyLifecycleController(
            monitor: hotkey,
            notificationCenter: NotificationCenter()
        )
        let recorder = LifecycleAudioRecorder()
        let (model, defaults, suiteName) = try makeModel(
            hotkeys: controller,
            recorder: recorder
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        model.phase = .listening

        model.setDictateActivationMode(.toggle)

        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(recorder.cancelCount, 1)
    }

    private func waitForPhase(
        _ expected: DictationPhase,
        on model: AppModel,
        timeout: Duration = .seconds(2)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if model.phase == expected { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.phase, expected, "Timed out waiting for phase \(expected)")
    }

    private func makeModel(
        hotkeys: HotkeyLifecycleController,
        recorder: any AudioRecording
    ) throws -> (AppModel, UserDefaults, String) {
        let suiteName = "ai.dictator.tests.lifecycle.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let model = AppModel(
            keychain: LifecycleCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
            connectivity: LifecycleConnectivityMonitor(),
            hotkeys: hotkeys,
            recorder: recorder
        )
        return (model, defaults, suiteName)
    }
}

@MainActor
private final class TestHotkeyMonitor: HotkeyMonitoring {
    var onPress: ((pid_t?) -> Void)?
    var onRelease: (() -> Void)?
    var onScreenAwarePress: ((pid_t?) -> Void)?
    var onScreenAwareRelease: (() -> Void)?
    var onPasteLatest: (() -> Void)?
    var onOpenClipboard: (() -> Void)?
    private(set) var isRunning: Bool
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var dictateIsDown: Bool
    private var startFailuresRemaining: Int

    init(
        isRunning: Bool,
        startFailuresRemaining: Int = 0,
        dictateIsDown: Bool = false
    ) {
        self.isRunning = isRunning
        self.startFailuresRemaining = startFailuresRemaining
        self.dictateIsDown = dictateIsDown
    }

    func configure(
        dictate: GlobalShortcut,
        dictateActivation: HotkeyActivationMode,
        pasteLatest: GlobalShortcut,
        openClipboard: GlobalShortcut
    ) {}

    func start() throws {
        startCount += 1
        if startFailuresRemaining > 0 {
            startFailuresRemaining -= 1
            throw HotkeyError.permissionRequired
        }
        isRunning = true
    }

    func stop() {
        stopCount += 1
        isRunning = false
        dictateIsDown = false
    }
}

@MainActor
private final class LifecycleAudioRecorder: AudioRecording {
    var onLevel: (@Sendable (Double) -> Void)?
    private(set) var cancelCount = 0
    private(set) var permissionRequestCount = 0

    func requestPermission() async -> Bool {
        permissionRequestCount += 1
        return true
    }
    func start() async throws {}
    func stop() async -> RecordedAudio {
        RecordedAudio(wavData: Data(), duration: 0)
    }
    func cancel() {
        cancelCount += 1
    }
}

@MainActor
private final class ManualHotkeyRecoveryScheduler {
    private var pending: (@MainActor () -> Bool)?
    private(set) var scheduleCount = 0
    var pendingCount: Int { pending == nil ? 0 : 1 }

    func schedule(
        _ recovery: @escaping @MainActor () -> Bool
    ) -> AnyCancellable {
        scheduleCount += 1
        pending = recovery
        return AnyCancellable { [weak self] in
            MainActor.assumeIsolated {
                self?.pending = nil
            }
        }
    }

    func fire() {
        guard let pending else { return }
        if pending() {
            self.pending = nil
        }
    }
}

private struct LifecycleCredentialStore: CredentialStoring {
    func save(
        _ credentials: ProviderCredentials,
        for purpose: ProviderPurpose,
        provider: ProviderKind
    ) throws {}

    func load(
        for purpose: ProviderPurpose,
        provider: ProviderKind
    ) throws -> ProviderCredentials? {
        nil
    }
}

private struct LifecycleConnectivityMonitor: ConnectivityMonitoring {
    let state: ConnectivityState = .online
}
