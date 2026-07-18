import ApplicationServices
import AppKit
import AVFoundation
import Combine
import CoreGraphics
import DictatorCore
import Foundation
import DictatorCore
import ImageIO
import XCTest
@testable import Dictator

@MainActor
final class AppBehaviorTests: XCTestCase {
    private final class FakeUpdateEngine: UpdateEngine {
        let canCheckSubject = CurrentValueSubject<Bool, Never>(false)
        var automaticallyChecksForUpdates = true
        var receivesCanaryUpdates = false {
            didSet {
                guard receivesCanaryUpdates != oldValue else { return }
                updateCycleResetCount += 1
            }
        }
        private(set) var checkCount = 0
        private(set) var updateCycleResetCount = 0

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

    func testHUDPositionModeDefaultsToNotchAndPersistsPointerSelection() throws {
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

        XCTAssertEqual(model.hudPositionMode, .notch)
        XCTAssertEqual(defaults.string(forKey: "hudPositionMode"), HUDPositionMode.notch.rawValue)

        model.setHUDPositionMode(.pointer)

        XCTAssertEqual(model.hudPositionMode, .pointer)
        XCTAssertEqual(defaults.string(forKey: "hudPositionMode"), HUDPositionMode.pointer.rawValue)
    }

    func testAppModelRestoresPointerHUDMode() throws {
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

    func testAppModelMigratesBottomHUDModeToNotch() throws {
        let suiteName = "ai.dictator.tests.hud-position-migration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("bottom", forKey: "hudPositionMode")

        let model = AppModel(
            keychain: HUDTestCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
            connectivity: HUDTestConnectivityMonitor()
        )

        XCTAssertEqual(model.hudPositionMode, .notch)
        XCTAssertEqual(defaults.string(forKey: "hudPositionMode"), HUDPositionMode.notch.rawValue)
    }

    func testSavedProviderCredentialsAreReportedAsConfiguredBeforeExpansion() throws {
        let suiteName = "ai.dictator.tests.provider-status.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            keychain: ConfiguredProviderCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
            connectivity: HUDTestConnectivityMonitor()
        )

        XCTAssertTrue(model.isProviderConfigured(purpose: .cleanup, provider: .groq))
    }

    func testScreenAwareDefaultsToSelectedCleanupProvider() throws {
        let suiteName = "ai.dictator.tests.screen-aware-default-provider.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(ProviderKind.groq.rawValue, forKey: "selectedLLM")
        let model = AppModel(
            keychain: HUDTestCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
            connectivity: HUDTestConnectivityMonitor()
        )

        XCTAssertEqual(model.selectedScreenAwareLLM, .groq)
    }

    func testScreenAwareConnectionTestImageIsDecodableJPEG() throws {
        let request = try ScreenAwareConnectionProbe.request()
        XCTAssertEqual(request.imageMIMEType, "image/jpeg")

        let source = try XCTUnwrap(CGImageSourceCreateWithData(request.imageData as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.jpeg")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))

        XCTAssertGreaterThanOrEqual(image.width, 2)
        XCTAssertGreaterThanOrEqual(image.height, 2)
    }

    func testScreenAwareConfirmationIsBoundToCredentialsAndBaseURL() throws {
        let suiteName = "ai.dictator.tests.screen-aware-confirmation-fingerprint.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            keychain: HUDTestCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
            connectivity: HUDTestConnectivityMonitor()
        )
        let provider = ProviderKind.openAICompatible
        let modelName = "vision-model"
        let original = ProviderCredentials(
            apiKey: "key-a",
            baseURL: URL(string: "https://one.example/v1")!
        )

        model.confirmScreenAwareModel(provider: provider, model: modelName, credentials: original)

        XCTAssertTrue(model.isScreenAwareModelConfirmed(provider: provider, model: modelName, credentials: original))
        XCTAssertFalse(model.isScreenAwareModelConfirmed(
            provider: provider,
            model: modelName,
            credentials: .init(apiKey: "key-b", baseURL: original.baseURL)
        ))
        XCTAssertFalse(model.isScreenAwareModelConfirmed(
            provider: provider,
            model: modelName,
            credentials: .init(apiKey: original.apiKey, baseURL: URL(string: "https://two.example/v1"))
        ))
    }

    func testScreenAwareConnectionTestConfirmsOnlyTheTestedConfiguration() async throws {
        let suiteName = "ai.dictator.tests.screen-aware-provider-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let provider = TestScreenAwareProvider(model: "vision-model")
        let model = AppModel(
            keychain: HUDTestCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
            connectivity: HUDTestConnectivityMonitor(),
            screenAwareProvider: { _ in provider }
        )
        let credentials = ProviderCredentials(apiKey: "tested-key", baseURL: URL(string: "https://example.com/v1"))

        try await model.testProviderConnection(
            purpose: .screenAware,
            provider: .openAICompatible,
            model: "vision-model",
            credentials: credentials
        )

        XCTAssertTrue(model.isScreenAwareModelConfirmed(
            provider: .openAICompatible,
            model: "vision-model",
            credentials: credentials
        ))
    }

    func testScreenAwareReusesSpeechCredentialForSameProvider() throws {
        let suiteName = "ai.dictator.tests.screen-aware-shared-credential.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(ProviderKind.groq.rawValue, forKey: "selectedScreenAwareLLM")
        let model = AppModel(
            keychain: SpeechOnlyGroqCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
            connectivity: HUDTestConnectivityMonitor()
        )

        XCTAssertEqual(model.credentials(purpose: .screenAware, provider: .groq)?.apiKey, "shared-key")
        XCTAssertTrue(model.screenAwareProviderIsConfigured)
    }

    func testScreenCapturePermissionCanRefreshAfterSettingsChange() throws {
        let suiteName = "ai.dictator.tests.screen-capture-permission-refresh.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let capture = TestScreenContextCapture()
        capture.permissionGranted = false
        let model = AppModel(
            keychain: HUDTestCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
            connectivity: HUDTestConnectivityMonitor(),
            screenCapture: capture
        )

        model.refreshScreenCapturePermission()
        XCTAssertFalse(model.screenCaptureGranted)
        capture.permissionGranted = true
        model.refreshScreenCapturePermission()
        XCTAssertTrue(model.screenCaptureGranted)
    }

    func testHUDShowsOnlyOneVisiblePanel() {
        let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let controller = FloatingPanelController()

        controller.show(.listening)

        let panels = NSApp.windows.filter {
            !existingWindows.contains(ObjectIdentifier($0)) && $0 is NSPanel
        }
        defer { panels.forEach { $0.close() } }
        XCTAssertEqual(panels.filter(\.isVisible).count, 1)
    }

    func testChangingVisibleHUDPositionDefersPanelResize() async throws {
        let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let pointer = NSPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
        let controller = FloatingPanelController(pointerLocation: { pointer })
        controller.show(.listening)
        let panel = try XCTUnwrap(NSApp.windows.first {
            !existingWindows.contains(ObjectIdentifier($0)) && $0 is NSPanel
        })
        defer { panel.close() }
        let notchFrame = panel.frame
        let pointerFrame = HUDPositioning.pointerFrame(
            size: notchFrame.size,
            pointer: pointer,
            visibleFrame: screen.visibleFrame
        )
        XCTAssertNotEqual(pointerFrame, notchFrame, "Test pointer must produce a visible frame change")
        let didMove = expectation(forNotification: NSWindow.didMoveNotification, object: panel)

        controller.setPositionMode(.pointer)

        XCTAssertEqual(panel.frame, notchFrame)
        await fulfillment(of: [didMove], timeout: 1)
        XCTAssertEqual(panel.frame.origin.x, pointerFrame.origin.x, accuracy: 1)
        XCTAssertEqual(panel.frame.origin.y, pointerFrame.origin.y, accuracy: 1)
        XCTAssertEqual(panel.frame.size, pointerFrame.size)
    }

    func testAudioTapHandlerRunsOutsideMainActor() async throws {
        let levels = AudioLevelRecorder()
        let recorder = AudioRecorder()
        recorder.onLevel = { levels.append($0) }
        let tap = recorder.makeTapHandler()

        try await Task.detached {
            let format = try XCTUnwrap(
                AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 2)
            )
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
            pcm.frameLength = 2
            let channels = try XCTUnwrap(pcm.floatChannelData)
            for channel in 0..<2 {
                channels[channel][0] = 0.01
                channels[channel][1] = 0.01
            }

            tap(pcm, AVAudioTime(hostTime: 0))
        }.value

        XCTAssertEqual(try XCTUnwrap(levels.values.first), 0.375, accuracy: 0.001)
    }

    func testHUDNotchFramePinsToTopCenter() {
        XCTAssertEqual(
            HUDPositioning.notchFrame(
                size: NSSize(width: 124, height: 32),
                screenFrame: NSRect(x: 0, y: 0, width: 1_440, height: 900)
            ),
            NSRect(x: 658, y: 868, width: 124, height: 32)
        )
    }

    func testHUDNotchFrameClearsTopSafeArea() {
        XCTAssertEqual(
            HUDPositioning.notchFrame(
                size: NSSize(width: 124, height: 32),
                screenFrame: NSRect(x: 0, y: 0, width: 1_512, height: 982),
                topSafeAreaInset: 32
            ),
            NSRect(x: 694, y: 918, width: 124, height: 32)
        )
    }

    func testHUDOnlyTracksPointerForVisiblePhases() {
        XCTAssertFalse(HUDPhase.idle.tracksPointer)
        XCTAssertTrue(HUDPhase.listening.tracksPointer)
        XCTAssertTrue(HUDPhase.transcribing.tracksPointer)
        XCTAssertTrue(HUDPhase.offline.tracksPointer)
        XCTAssertTrue(HUDPhase.cleaning.tracksPointer)
        XCTAssertTrue(HUDPhase.understanding.tracksPointer)
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

    func testScreenWindowMatcherChoosesTheUniqueFocusedWindow() {
        let focused = FocusedWindowSnapshot(
            processIdentifier: 42,
            applicationName: "Mail",
            bundleIdentifier: "com.apple.mail",
            title: "Inbox",
            frame: CGRect(x: 100, y: 100, width: 900, height: 700)
        )
        let candidates = [
            ScreenWindowDescriptor(id: 1, processIdentifier: 42, title: "Inbox", frame: focused.frame),
            ScreenWindowDescriptor(id: 2, processIdentifier: 42, title: "Compose", frame: CGRect(x: 180, y: 150, width: 700, height: 500)),
            ScreenWindowDescriptor(id: 3, processIdentifier: 7, title: "Inbox", frame: focused.frame),
        ]

        XCTAssertEqual(ScreenWindowMatcher.match(focused: focused, candidates: candidates)?.id, 1)
    }

    func testScreenWindowMatcherRejectsAnAmbiguousFocusedWindow() {
        let focused = FocusedWindowSnapshot(
            processIdentifier: 42,
            applicationName: "Browser",
            bundleIdentifier: "com.example.browser",
            title: nil,
            frame: CGRect(x: 100, y: 100, width: 900, height: 700)
        )
        let candidates = [
            ScreenWindowDescriptor(id: 1, processIdentifier: 42, title: "One", frame: focused.frame),
            ScreenWindowDescriptor(id: 2, processIdentifier: 42, title: "Two", frame: focused.frame),
        ]

        XCTAssertNil(ScreenWindowMatcher.match(focused: focused, candidates: candidates))
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

    func testTextOnlyScreenAwareModelFailsBeforeRecordingOrCapture() async throws {
        let suiteName = "ai.dictator.tests.screen-aware-capability.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "screenAwareEnabled")
        defaults.set(ProviderKind.groq.rawValue, forKey: "selectedScreenAwareLLM")
        defaults.set("openai/gpt-oss-20b", forKey: "visionModel.groq")
        let recorder = TestAudioRecorder()
        let capture = TestScreenContextCapture()
        let model = AppModel(
            keychain: ScreenAwareCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
            connectivity: HUDTestConnectivityMonitor(),
            recorder: recorder,
            screenCapture: capture
        )

        await model.startScreenAwareDictation()

        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(recorder.permissionRequestCount, 0)
        XCTAssertEqual(capture.captureCount, 0)
        XCTAssertEqual(model.lastError, "The selected model does not support image input. Choose a vision-capable model.")
    }

    func testScreenAwareHappyPathUsesOneRunAndRecordsItsLLMExecution() async throws {
        let suiteName = "ai.dictator.tests.screen-aware-happy-path.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "screenAwareEnabled")
        defaults.set(ProviderKind.groq.rawValue, forKey: "selectedScreenAwareLLM")
        let modelName = "meta-llama/llama-4-scout-17b-16e-instruct"
        defaults.set(modelName, forKey: "visionModel.groq")

        let recorder = TestAudioRecorder()
        recorder.recordedAudio = .init(wavData: Data([1]), duration: 1)
        let target = ApplicationTarget(
            element: AXUIElementCreateApplication(4242),
            name: "Mail",
            bundleIdentifier: "com.apple.mail",
            processIdentifier: 4242
        )
        let focusedTarget = FocusedTarget.application(target)
        let window = FocusedWindowSnapshot(
            processIdentifier: 4242,
            applicationName: "Mail",
            bundleIdentifier: "com.apple.mail",
            title: "Reply",
            frame: CGRect(x: 10, y: 10, width: 800, height: 600)
        )
        let inserter = TestTargetInserter(target: focusedTarget, window: window)
        let capture = TestScreenContextCapture()
        capture.capturedContext = .init(imageData: Data([1, 2]), imageMIMEType: "image/jpeg", window: window)
        let transcription = TestTranscriptionCoordinator(result: .init(
            result: .init(text: "Reply that Tuesday works", provider: .groq, model: "whisper", latency: 0.1),
            mode: .online
        ))
        let provider = TestScreenAwareProvider(model: modelName)
        let model = AppModel(
            keychain: ScreenAwareCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
            connectivity: HUDTestConnectivityMonitor(),
            recorder: recorder,
            screenCapture: capture,
            transcriptionCoordinator: transcription,
            inserter: inserter,
            screenAwareProvider: { _ in provider }
        )

        await model.startScreenAwareDictation(targetProcessIdentifier: 4242)
        await model.stopDictation()

        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(inserter.insertedText, "Hi Sam,\n\nTuesday works for me.")
        XCTAssertEqual(capture.captureCount, 1)
        let record = try XCTUnwrap(model.data.transcripts.first)
        XCTAssertEqual(record.sourceBundleID, "com.apple.mail")
        XCTAssertEqual(record.llmExecution?.purpose, .screenAware)
        XCTAssertEqual(record.llmExecution?.provider, .groq)
        XCTAssertEqual(record.llmExecution?.model, modelName)
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

    func testInsertionPreservesParagraphBreaks() async {
        let fixture = InsertionFixture(bundleIdentifier: "com.apple.mail")
        let email = "Hi Sam,\n\nThanks for the update. I will review it today.\n\nBest,\nAmal"

        let result = await fixture.inserter.insert(.dictation(email), into: .application(fixture.application))

        XCTAssertEqual(result, .pasteCommandPosted(.activeApplication))
        XCTAssertEqual(fixture.clipboard.lastPreparedText, email)
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

    func testUpdaterPersistsCanaryPreferenceAndResetsUpdateCycle() throws {
        let suiteName = "AppBehaviorTests.canary.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let engine = FakeUpdateEngine()
        let updater = AppUpdater(
            engine: engine,
            bundle: try updaterTestBundle(),
            defaults: defaults
        )

        XCTAssertFalse(updater.receivesCanaryUpdates)
        XCTAssertFalse(engine.receivesCanaryUpdates)

        updater.receivesCanaryUpdates = true

        XCTAssertTrue(engine.receivesCanaryUpdates)
        XCTAssertTrue(defaults.bool(forKey: "receiveCanaryUpdates"))
        XCTAssertEqual(engine.updateCycleResetCount, 1)
    }

    func testUpdaterRestoresCanaryPreferenceBeforeUse() throws {
        let suiteName = "AppBehaviorTests.canary.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "receiveCanaryUpdates")
        let engine = FakeUpdateEngine()

        let updater = AppUpdater(
            engine: engine,
            bundle: try updaterTestBundle(),
            defaults: defaults
        )

        XCTAssertTrue(updater.receivesCanaryUpdates)
        XCTAssertTrue(engine.receivesCanaryUpdates)
    }

    func testSparkleDelegateAllowsOnlyOptedInCanaryChannel() {
        let delegate = SparkleUpdateDelegate(receivesCanaryUpdates: false)
        XCTAssertEqual(delegate.allowedChannels, [])

        delegate.receivesCanaryUpdates = true
        XCTAssertEqual(delegate.allowedChannels, ["canary"])
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

private struct ConfiguredProviderCredentialStore: CredentialStoring {
    func save(_ credentials: ProviderCredentials, for purpose: ProviderPurpose, provider: ProviderKind) throws {}

    func load(for purpose: ProviderPurpose, provider: ProviderKind) throws -> ProviderCredentials? {
        guard case .cleanup = purpose, provider == .groq else { return nil }
        return ProviderCredentials(apiKey: "test-key")
    }
}

private struct SpeechOnlyGroqCredentialStore: CredentialStoring {
    func save(_ credentials: ProviderCredentials, for purpose: ProviderPurpose, provider: ProviderKind) throws {}

    func load(for purpose: ProviderPurpose, provider: ProviderKind) throws -> ProviderCredentials? {
        guard purpose == .speechToText, provider == .groq else { return nil }
        return ProviderCredentials(apiKey: "shared-key")
    }
}

@MainActor
private final class TestAudioRecorder: AudioRecording {
    var onLevel: (@Sendable (Double) -> Void)?
    var recordedAudio = RecordedAudio(wavData: Data(), duration: 0)
    private(set) var cancelCount = 0
    private(set) var permissionRequestCount = 0

    func requestPermission() async -> Bool {
        permissionRequestCount += 1
        return true
    }
    func start() throws {}
    func stop() -> RecordedAudio { recordedAudio }
    func cancel() { cancelCount += 1 }
}

@MainActor
private final class TestScreenContextCapture: ScreenContextCapturing {
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
private final class TestTranscriptionCoordinator: TranscriptionCoordinating {
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
private final class TestTargetInserter: FocusedTargetInserting {
    let target: FocusedTarget
    let window: FocusedWindowSnapshot
    private(set) var insertedText: String?

    init(target: FocusedTarget, window: FocusedWindowSnapshot) {
        self.target = target
        self.window = window
    }

    func captureFocusedTarget(processIdentifier: pid_t?) -> FocusedTarget? { target }
    func captureFocusedWindow(for target: FocusedTarget) -> FocusedWindowSnapshot? { window }
    func insert(_ insertion: TextInsertion, into target: FocusedTarget?) async -> InsertionResult {
        insertedText = insertion.text
        return .pasteCommandPosted(.activeApplication)
    }
    func pasteIntoFrontmostApp(_ text: String) async -> Bool { true }
}

private struct TestScreenAwareProvider: ScreenAwareLLMProvider {
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

private struct ScreenAwareCredentialStore: CredentialStoring {
    func save(_ credentials: ProviderCredentials, for purpose: ProviderPurpose, provider: ProviderKind) throws {}

    func load(for purpose: ProviderPurpose, provider: ProviderKind) throws -> ProviderCredentials? {
        guard purpose == .screenAware, provider == .groq else { return nil }
        return ProviderCredentials(apiKey: "test-key")
    }
}

private final class AudioLevelRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    var values: [Double] { lock.withLock { storage } }
    func append(_ value: Double) { lock.withLock { storage.append(value) } }
}

private struct HUDTestConnectivityMonitor: ConnectivityMonitoring {
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
private final class TestEventRecorder {
    var events: [PostedKeyEvent] = []
    var failureIndex: Int?

    func post(_ event: PostedKeyEvent) -> Bool {
        let index = events.count
        events.append(event)
        return index != failureIndex
    }
}
