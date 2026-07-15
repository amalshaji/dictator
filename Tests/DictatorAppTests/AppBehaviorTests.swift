import ApplicationServices
import AppKit
import Combine
import CoreGraphics
import DictatorCore
import Foundation
import DictatorCore
import XCTest
@testable import Dictator

@MainActor
final class AppBehaviorTests: XCTestCase {
    private final class FakeUpdateEngine: UpdateEngine {
        let canCheckSubject = CurrentValueSubject<Bool, Never>(false)
        var automaticallyChecksForUpdates = true
        private(set) var checkCount = 0

        var canCheckForUpdatesPublisher: AnyPublisher<Bool, Never> {
            canCheckSubject.eraseToAnyPublisher()
        }

        func checkForUpdates() {
            checkCount += 1
        }
    }

    func testWindowChromeBackgroundMatchesSidebarAndContentAtEveryWidth() throws {
        for width in [920.0, 1_400.0] {
            let image = WindowChromeStyle.backgroundImage(windowWidth: width)
            let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            func color(at point: CGFloat) -> NSColor? {
                let pixel = min(bitmap.pixelsWide - 1, Int(point / image.size.width * CGFloat(bitmap.pixelsWide)))
                return bitmap.colorAt(x: pixel, y: 0)
            }

            XCTAssertEqual(image.size.width, width)
            assertColor(color(at: 0), red: 23, green: 21, blue: 26)
            assertColor(color(at: DictatorDesign.sidebarWidth - 1), red: 23, green: 21, blue: 26)
            assertColor(color(at: DictatorDesign.sidebarWidth), red: 246, green: 244, blue: 240)
            assertColor(color(at: width - 1), red: 246, green: 244, blue: 240)
        }
    }

    func testHUDPositionModeDefaultsToBottomAndPersistsPointerSelection() throws {
        let suiteName = "ai.dictator.tests.hud-position.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("unsupported", forKey: "hudPositionMode")

        let model = AppModel(
            keychain: HUDTestCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
            connectivity: HUDTestConnectivityMonitor()
        )

        XCTAssertEqual(model.hudPositionMode, .bottom)

        model.setHUDPositionMode(.pointer)

        XCTAssertEqual(model.hudPositionMode, .pointer)
        XCTAssertEqual(defaults.string(forKey: "hudPositionMode"), HUDPositionMode.pointer.rawValue)
    }

    func testAppModelRestoresPointerHUDModeWithoutShowingPanel() throws {
        let suiteName = "ai.dictator.tests.hud-position-restoration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(HUDPositionMode.pointer.rawValue, forKey: "hudPositionMode")

        let model = AppModel(
            keychain: HUDTestCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
            connectivity: HUDTestConnectivityMonitor()
        )

        XCTAssertEqual(model.hudPositionMode, .pointer)
    }

    func testHUDOnlyTracksPointerForActivePhases() {
        XCTAssertFalse(HUDPhase.idle.tracksPointer)
        XCTAssertTrue(HUDPhase.listening.tracksPointer)
        XCTAssertTrue(HUDPhase.transcribing.tracksPointer)
        XCTAssertTrue(HUDPhase.offline.tracksPointer)
        XCTAssertTrue(HUDPhase.cleaning.tracksPointer)
        XCTAssertTrue(HUDPhase.success("Done").tracksPointer)
        XCTAssertTrue(HUDPhase.clipboard.tracksPointer)
        XCTAssertTrue(HUDPhase.error("Failed").tracksPointer)
    }

    func testHUDPointerFrameUsesPreferredAboveRightOffset() {
        let frame = HUDPositioning.pointerFrame(
            size: NSSize(width: 124, height: 32),
            pointer: NSPoint(x: 400, y: 300),
            visibleFrame: NSRect(x: 0, y: 0, width: 1_440, height: 900)
        )

        XCTAssertEqual(frame, NSRect(x: 416, y: 316, width: 124, height: 32))
    }

    func testHUDPointerFrameFlipsAtRightAndTopEdges() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let size = NSSize(width: 260, height: 36)

        XCTAssertEqual(
            HUDPositioning.pointerFrame(
                size: size,
                pointer: NSPoint(x: 1_430, y: 300),
                visibleFrame: visibleFrame
            ),
            NSRect(x: 1_154, y: 316, width: 260, height: 36)
        )
        XCTAssertEqual(
            HUDPositioning.pointerFrame(
                size: size,
                pointer: NSPoint(x: 400, y: 890),
                visibleFrame: visibleFrame
            ),
            NSRect(x: 416, y: 838, width: 260, height: 36)
        )
    }

    func testHUDPointerFrameUsesPreferredOffsetAtLeftAndBottomEdges() {
        let frame = HUDPositioning.pointerFrame(
            size: NSSize(width: 260, height: 36),
            pointer: NSPoint(x: 2, y: 2),
            visibleFrame: NSRect(x: 0, y: 0, width: 1_440, height: 900)
        )

        XCTAssertEqual(frame, NSRect(x: 18, y: 18, width: 260, height: 36))
    }

    func testHUDPointerFrameConstrainsOversizedPillToVisibleBounds() {
        let frame = HUDPositioning.pointerFrame(
            size: NSSize(width: 260, height: 100),
            pointer: NSPoint(x: 100, y: 40),
            visibleFrame: NSRect(x: 0, y: 0, width: 200, height: 80)
        )

        XCTAssertEqual(frame, NSRect(x: 8, y: 8, width: 184, height: 64))
    }

    func testHUDPointerFrameRespectsInsetOnNegativeCoordinateDisplay() {
        let frame = HUDPositioning.pointerFrame(
            size: NSSize(width: 260, height: 36),
            pointer: NSPoint(x: -10, y: 1_070),
            visibleFrame: NSRect(x: -1_920, y: 0, width: 1_920, height: 1_080)
        )

        XCTAssertEqual(frame, NSRect(x: -286, y: 1_018, width: 260, height: 36))
    }

    func testTranscriptMetadataLabelsSTTProviderAndLatency() {
        let record = TranscriptRecord(
            rawText: "Hello", finalText: "Hello", sttProvider: .groq, sttModel: "whisper",
            audioDuration: 1, sttLatency: 0.301, insertionOutcome: "inserted"
        )

        XCTAssertEqual(
            TranscriptMetadataFormatter.pipelineSegments(for: record),
            ["STT: Groq, 301 ms", "Total: —"]
        )
    }

    func testTranscriptMetadataLabelsCleanupAndTotalPipelineLatency() {
        let record = TranscriptRecord(
            rawText: "hello", finalText: "Hello.", sttProvider: .groq, sttModel: "whisper",
            audioDuration: 1, sttLatency: 0.301, pipelineLatency: 0.612,
            cleanup: .init(provider: .groq, model: "gpt-oss", latency: 0.184),
            insertionOutcome: "inserted"
        )

        XCTAssertEqual(
            TranscriptMetadataFormatter.pipelineSegments(for: record),
            ["STT: Groq, 301 ms", "Cleanup: Groq, 184 ms", "Total: 612 ms"]
        )
    }

    func testUsageCurrencyFormattingUsesStableFractionPrecision() {
        XCTAssertEqual(
            UsageDisplayFormatter.currency(Decimal(string: "0.0119277777777777793024")!, complete: true),
            "$0.0119"
        )
        XCTAssertEqual(UsageDisplayFormatter.currency(2, complete: true), "$2.00")
        XCTAssertEqual(UsageDisplayFormatter.currency(1, complete: false), "Partially available")
    }

    func testPrivateClipboardShortcutsAreExact() {
        let shortcut = GlobalShortcut(keyCode: 8, modifiers: [.maskCommand, .maskControl], keyLabel: "C")
        XCTAssertTrue(ShortcutMatcher.matches(shortcut, keyCode: 8, flags: [.maskCommand, .maskControl]))
        XCTAssertFalse(ShortcutMatcher.matches(shortcut, keyCode: 8, flags: [.maskCommand]))
        XCTAssertFalse(ShortcutMatcher.matches(shortcut, keyCode: 9, flags: [.maskCommand, .maskControl]))
        XCTAssertEqual(shortcut.displayName, "⌃⌘C")
    }

    func testEachWakeRecreatesHotkeyMonitorEvenWhenItReportsRunning() {
        let notifications = NotificationCenter()
        let hotkey = TestHotkeyMonitor(isRunning: true)
        let controller = HotkeyLifecycleController(
            monitor: hotkey,
            notificationCenter: notifications
        )

        for _ in 0..<2 {
            notifications.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
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
        let recorder = TestAudioRecorder()
        let (model, defaults, suiteName) = try makeLifecycleModel(
            hotkeys: controller,
            recorder: recorder
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        model.phase = .listening

        notifications.post(name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)

        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(recorder.cancelCount, 1)
        XCTAssertEqual(hotkey.stopCount, 1)
        XCTAssertFalse(model.shortcutsAvailable)
    }

    func testRepeatedSleepWakeCyclesResetHeldStateAndPreserveAllCallbacks() {
        let notifications = NotificationCenter()
        let hotkey = TestHotkeyMonitor(isRunning: true, dictateIsDown: true)
        let controller = HotkeyLifecycleController(
            monitor: hotkey,
            notificationCenter: notifications
        )
        var pasteCount = 0
        var clipboardCount = 0
        controller.onPasteLatest = { pasteCount += 1 }
        controller.onOpenClipboard = { clipboardCount += 1 }

        for _ in 0..<2 {
            notifications.post(name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)
            XCTAssertFalse(hotkey.dictateIsDown)
            notifications.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
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
        let hotkey = TestHotkeyMonitor(isRunning: true, startFailuresRemaining: 2)
        let scheduler = ManualHotkeyRecoveryScheduler()
        let controller = HotkeyLifecycleController(
            monitor: hotkey,
            notificationCenter: notifications,
            scheduleRecovery: scheduler.schedule
        )

        notifications.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
        notifications.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)

        XCTAssertEqual(hotkey.startCount, 2)
        XCTAssertEqual(scheduler.scheduleCount, 2)
        XCTAssertEqual(scheduler.pendingCount, 1)
        XCTAssertEqual(controller.state, .unavailable(HotkeyError.permissionRequired.localizedDescription))

        scheduler.fire()

        XCTAssertEqual(hotkey.startCount, 3)
        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertEqual(controller.state, .available)
    }

    func testStoppingHotkeyMonitorClearsHeldFunctionState() throws {
        let monitor = HotkeyMonitor()
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: true))
        event.flags = .maskSecondaryFn
        var pressCount = 0
        monitor.onPress = { _ in pressCount += 1 }

        _ = monitor.handle(event, type: .flagsChanged)
        monitor.stop()
        _ = monitor.handle(event, type: .flagsChanged)

        XCTAssertEqual(pressCount, 2)
    }

    func testHotkeyHealthRequiresValidEnabledTap() {
        XCTAssertTrue(HotkeyMonitor.isTapHealthy(isValid: true, isEnabled: true))
        XCTAssertFalse(HotkeyMonitor.isTapHealthy(isValid: false, isEnabled: true))
        XCTAssertFalse(HotkeyMonitor.isTapHealthy(isValid: true, isEnabled: false))
    }

    func testDisabledStyleCannotBeSelected() {
        let model = AppModel()
        let disabled = WritingStyle(name: "Disabled", instruction: "Do not use", isEnabled: false)
        model.data.styles = [disabled]
        model.selectedStyleID = nil
        model.selectStyle(disabled.id)
        XCTAssertNil(model.selectedStyleID)
    }

    func testAppleSpeechSetupIgnoresStaleLocaleReadiness() async throws {
        let provider = DelayedAppleSpeechProvider()
        let coordinator = AppleSpeechCoordinator(
            provider: provider,
            selectedLocaleIdentifier: "en_US",
            persistSelection: { _ in }
        )
        let initialRefresh = Task { await coordinator.refresh() }

        while coordinator.state.locales.isEmpty { await Task.yield() }
        coordinator.selectLocale("fr_FR")
        try await Task.sleep(for: .milliseconds(200))
        await initialRefresh.value

        XCTAssertEqual(coordinator.state.selectedLocaleIdentifier, "fr_FR")
        XCTAssertEqual(
            coordinator.state.readyLocale,
            AppleSpeechLocale(identifier: "fr_FR", engine: .speechTranscriber)
        )
    }

    func testMissingFocusedTargetNeverTouchesAnotherApp() async {
        let result = await AccessibilityInserter().insert(.dictation("private text"), into: nil)
        XCTAssertEqual(result, .privateClipboard("no editable field was focused"))
    }

    func testResolverPrefersExactEditableTarget() {
        let fixture = InsertionFixture()

        let target = AccessibilityTargetResolver.resolve(
            application: fixture.application,
            candidates: [
                .editable(
                    processIdentifier: fixture.targetPID,
                    element: fixture.fieldElement,
                    selection: fixture.originalSelection
                )
            ]
        )

        guard case .field(let application, let element, let selection) = target else {
            return XCTFail("Expected an exact field target")
        }
        XCTAssertEqual(application.processIdentifier, fixture.targetPID)
        XCTAssertTrue(CFEqual(element, fixture.fieldElement))
        XCTAssertEqual(selection, fixture.originalSelection)
    }

    func testResolverUsesApplicationFallbackWithoutAllowlist() {
        let fixture = InsertionFixture(bundleIdentifier: "com.example.custom-editor")

        let target = AccessibilityTargetResolver.resolve(application: fixture.application, candidates: [])

        guard case .application(let application) = target else {
            return XCTFail("Expected an application fallback")
        }
        XCTAssertEqual(application.bundleIdentifier, "com.example.custom-editor")
    }

    func testResolverBlocksKnownSecureField() async {
        let fixture = InsertionFixture()
        let target = AccessibilityTargetResolver.resolve(
            application: fixture.application,
            candidates: [.secure(processIdentifier: fixture.targetPID)]
        )

        let result = await fixture.inserter.insert(.dictation("secret"), into: target)

        XCTAssertEqual(result, .privateClipboard("secure fields are never modified"))
        XCTAssertTrue(fixture.events.events.isEmpty)
    }

    func testResolverIgnoresFocusedCandidateFromAnotherProcess() {
        let fixture = InsertionFixture()

        let target = AccessibilityTargetResolver.resolve(
            application: fixture.application,
            candidates: [.secure(processIdentifier: 777)]
        )

        guard case .application = target else {
            return XCTFail("A candidate from another process must not become the target")
        }
    }

    func testApplicationFallbackPastesWhenOriginalAppRemainsFrontmost() async {
        let fixture = InsertionFixture(bundleIdentifier: "com.openai.codex")

        let result = await fixture.inserter.insert(.dictation("hello ChatGPT"), into: .application(fixture.application))

        XCTAssertEqual(result, .pasteCommandPosted(.activeApplication))
        XCTAssertEqual(fixture.events.events, Self.expectedPasteEvents)
        XCTAssertTrue(fixture.clipboard.didRestore)
    }

    func testApplicationFallbackDoesNotPasteAfterAppSwitch() async {
        let fixture = InsertionFixture()
        fixture.applicationState.frontmostPID = 777

        let result = await fixture.inserter.insert(.dictation("do not paste"), into: .application(fixture.application))

        XCTAssertEqual(result, .privateClipboard("focus moved to another application"))
        XCTAssertTrue(fixture.events.events.isEmpty)
    }

    func testDeadTargetFallsBackToPrivateClipboard() async {
        let fixture = InsertionFixture()
        fixture.applicationState.runningPIDs.remove(fixture.targetPID)

        let result = await fixture.inserter.insert(.dictation("do not paste"), into: .application(fixture.application))

        XCTAssertEqual(result, .privateClipboard("the target application is no longer running"))
        XCTAssertTrue(fixture.events.events.isEmpty)
    }

    func testExactTargetReactivatesAndPastesEvenWhenAXRefocusIsRejected() async {
        let fixture = InsertionFixture()
        fixture.applicationState.frontmostPID = 777
        fixture.applicationState.focusSucceeds = false

        let result = await fixture.inserter.insert(
            .dictation("exact"),
            into: .field(application: fixture.application, element: fixture.fieldElement, selection: nil)
        )

        XCTAssertEqual(result, .pasteCommandPosted(.capturedField))
        XCTAssertEqual(fixture.applicationState.activatedPIDs, [fixture.targetPID])
        XCTAssertEqual(fixture.applicationState.focusAttempts, 1)
        XCTAssertEqual(fixture.events.events, Self.expectedPasteEvents)
    }

    func testPasteEventFailureRestoresOwnedClipboard() async {
        let fixture = InsertionFixture()
        fixture.events.failureIndex = 1

        let result = await fixture.inserter.insert(.dictation("failed"), into: .application(fixture.application))

        XCTAssertEqual(result, .privateClipboard("the paste shortcut could not be posted"))
        XCTAssertTrue(fixture.clipboard.didRestore)
    }

    func testClipboardPreparationFailureRestoresSnapshot() async {
        let fixture = InsertionFixture()
        fixture.clipboard.prepareSucceeds = false

        let result = await fixture.inserter.insert(.dictation("failed"), into: .application(fixture.application))

        XCTAssertEqual(result, .privateClipboard("the paste shortcut could not be posted"))
        XCTAssertTrue(fixture.clipboard.didRestore)
        XCTAssertTrue(fixture.events.events.isEmpty)
    }

    func testExternallyChangedClipboardIsNotOverwritten() async {
        let fixture = InsertionFixture()
        fixture.clipboard.ownsPreparedContents = false

        let result = await fixture.inserter.insert(.dictation("paste"), into: .application(fixture.application))

        XCTAssertEqual(result, .pasteCommandPosted(.activeApplication))
        XCTAssertFalse(fixture.clipboard.didRestore)
    }

    func testTransformationPastesWhenCapturedSelectionStillMatches() async {
        let fixture = InsertionFixture()

        let result = await fixture.inserter.insert(
            .transformation("selected text", expectedSelection: fixture.originalSelection),
            into: .field(
                application: fixture.application,
                element: fixture.fieldElement,
                selection: fixture.originalSelection
            )
        )

        XCTAssertEqual(result, .pasteCommandPosted(.capturedField))
        XCTAssertEqual(fixture.events.events, Self.expectedPasteEvents)
    }

    func testTransformationDoesNotPasteAfterSelectionChanges() async {
        let fixture = InsertionFixture()
        fixture.applicationState.currentSelection = TextSelectionSnapshot(
            text: "DIFFERENT TEXT",
            location: 20,
            length: 14
        )

        let result = await fixture.inserter.insert(
            .transformation("selected text", expectedSelection: fixture.originalSelection),
            into: .field(
                application: fixture.application,
                element: fixture.fieldElement,
                selection: fixture.originalSelection
            )
        )

        XCTAssertEqual(result, .privateClipboard("the selected text changed before transformation"))
        XCTAssertTrue(fixture.events.events.isEmpty)
    }

    func testUpdaterForwardsAvailabilityAndManualChecks() throws {
        let engine = FakeUpdateEngine()
        let updater = AppUpdater(engine: engine, bundle: try updaterTestBundle())

        XCTAssertFalse(updater.canCheckForUpdates)
        engine.canCheckSubject.send(true)
        XCTAssertTrue(updater.canCheckForUpdates)

        updater.checkForUpdates()
        XCTAssertEqual(engine.checkCount, 1)
        XCTAssertEqual(updater.versionDescription, "Version 1.2.3 (45)")
    }

    func testUpdaterWritesAutomaticCheckPreferenceToSparkleEngine() throws {
        let engine = FakeUpdateEngine()
        let updater = AppUpdater(engine: engine, bundle: try updaterTestBundle())

        XCTAssertTrue(updater.automaticallyChecksForUpdates)
        updater.automaticallyChecksForUpdates = false
        XCTAssertFalse(engine.automaticallyChecksForUpdates)
    }

    private func updaterTestBundle() throws -> Bundle {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: "UpdaterTests.bundle", directoryHint: .isDirectory)
        let contents = root.appending(path: "Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "ai.dictator.tests.updater",
            "CFBundlePackageType": "BNDL",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "45",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appending(path: "Info.plist"))
        return try XCTUnwrap(Bundle(url: root))
    }

    private func makeLifecycleModel(
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

    private func assertColor(
        _ color: NSColor?,
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let color = color?.usingColorSpace(.deviceRGB) else {
            return XCTFail("Expected an RGB color", file: file, line: line)
        }
        XCTAssertEqual(color.redComponent, red / 255, accuracy: 0.04, file: file, line: line)
        XCTAssertEqual(color.greenComponent, green / 255, accuracy: 0.04, file: file, line: line)
        XCTAssertEqual(color.blueComponent, blue / 255, accuracy: 0.04, file: file, line: line)
        XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.001, file: file, line: line)
    }

    private static let expectedPasteEvents = [
        PostedKeyEvent(keyCode: 0x09, keyDown: true, flags: .maskCommand),
        PostedKeyEvent(keyCode: 0x09, keyDown: false, flags: .maskCommand),
    ]
}

private struct HUDTestCredentialStore: CredentialStoring {
    func save(_ credentials: ProviderCredentials, for purpose: ProviderPurpose, provider: ProviderKind) throws {}
    func load(for purpose: ProviderPurpose, provider: ProviderKind) throws -> ProviderCredentials? { nil }
}

@MainActor
private final class TestHotkeyMonitor: HotkeyMonitoring {
    var onPress: ((pid_t?) -> Void)?
    var onRelease: (() -> Void)?
    var onPasteLatest: (() -> Void)?
    var onOpenClipboard: (() -> Void)?
    private(set) var isRunning: Bool
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var dictateIsDown: Bool
    private var startFailuresRemaining: Int

    init(isRunning: Bool, startFailuresRemaining: Int = 0, dictateIsDown: Bool = false) {
        self.isRunning = isRunning
        self.startFailuresRemaining = startFailuresRemaining
        self.dictateIsDown = dictateIsDown
    }

    func configure(dictate: GlobalShortcut, pasteLatest: GlobalShortcut, openClipboard: GlobalShortcut) {}

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
private final class TestAudioRecorder: AudioRecording {
    var onLevel: (@Sendable (Double) -> Void)?
    private(set) var cancelCount = 0

    func requestPermission() async -> Bool { true }
    func start() throws {}
    func stop() -> RecordedAudio { RecordedAudio(wavData: Data(), duration: 0) }
    func cancel() { cancelCount += 1 }
}

@MainActor
private final class ManualHotkeyRecoveryScheduler {
    private var pending: (@MainActor () -> Bool)?
    private(set) var scheduleCount = 0
    var pendingCount: Int { pending == nil ? 0 : 1 }

    func schedule(_ recovery: @escaping @MainActor () -> Bool) -> AnyCancellable {
        scheduleCount += 1
        pending = recovery
        return AnyCancellable { [weak self] in
            MainActor.assumeIsolated { self?.pending = nil }
        }
    }

    func fire() {
        guard let pending else { return }
        if pending() { self.pending = nil }
    }
}

private struct LifecycleCredentialStore: CredentialStoring {
    func save(_ credentials: ProviderCredentials, for purpose: ProviderPurpose, provider: ProviderKind) throws {}
    func load(for purpose: ProviderPurpose, provider: ProviderKind) throws -> ProviderCredentials? { nil }
}

private struct HUDTestConnectivityMonitor: ConnectivityMonitoring {
    let state: ConnectivityState = .online
}

private struct LifecycleConnectivityMonitor: ConnectivityMonitoring {
    let state: ConnectivityState = .online
}

private actor DelayedAppleSpeechProvider: LocalSpeechTranscribing {
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
private final class InsertionFixture {
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
private final class TestApplicationState {
    var frontmostPID: pid_t?
    var runningPIDs: Set<pid_t> = []
    var activatedPIDs: [pid_t] = []
    var activationSucceeds = true
    var focusSucceeds = true
    var focusAttempts = 0
    var currentSelection: TextSelectionSnapshot?
}

@MainActor
private final class TestClipboard: ClipboardAccess {
    var ownsPreparedContents = true
    var prepareSucceeds = true
    var didRestore = false
    private var preparedText: String?
    private var preparedSessionID: String?

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
private final class TestEventRecorder {
    var events: [PostedKeyEvent] = []
    var failureIndex: Int?

    func post(_ event: PostedKeyEvent) -> Bool {
        let index = events.count
        events.append(event)
        return index != failureIndex
    }
}
