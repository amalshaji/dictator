import AppKit
import Combine
import DictatorCore
import Foundation
import XCTest
@testable import Dictator

@MainActor
final class HotkeyLifecycleControllerTests: XCTestCase {
    func testEachWakeRecreatesHotkeyMonitorEvenWhenItReportsRunning() {
        let notifications = NotificationCenter()
        let hotkey = TestHotkeyMonitor(isRunning: true)
        let controller = HotkeyLifecycleController(
            monitor: hotkey,
            notificationCenter: notifications
        )

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

    func requestPermission() async -> Bool { true }
    func start() throws {}
    func stop() -> RecordedAudio {
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
