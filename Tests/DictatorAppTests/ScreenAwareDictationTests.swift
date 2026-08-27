import AppKit
import CoreGraphics
import DictatorCore
import Foundation
import ImageIO
import XCTest
@testable import Dictator

@MainActor
final class ScreenAwareDictationTests: XCTestCase {
    func testScreenAwareDefaultsToSelectedCleanupProvider() throws {
        let suiteName = "ai.dictator.tests.screen-aware-default-provider.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(ProviderKind.groq.rawValue, forKey: "selectedLLM")
        let model = AppModel(
            keychain: AppTestCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
            connectivity: AppTestConnectivityMonitor()
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
            keychain: AppTestCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
            connectivity: AppTestConnectivityMonitor()
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
            keychain: AppTestCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
            connectivity: AppTestConnectivityMonitor(),
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
            connectivity: AppTestConnectivityMonitor()
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
            keychain: AppTestCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
            connectivity: AppTestConnectivityMonitor(),
            screenCapture: capture
        )

        model.refreshScreenCapturePermission()
        XCTAssertFalse(model.screenCaptureGranted)
        capture.permissionGranted = true
        model.refreshScreenCapturePermission()
        XCTAssertTrue(model.screenCaptureGranted)
    }

    func testAppActivationRefreshesPermissionFromOutsideMainActor() async throws {
        let suiteName = "ai.dictator.tests.app-activation-permission-refresh.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let capture = TestScreenContextCapture()
        capture.permissionGranted = false
        let model = AppModel(
            keychain: AppTestCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
            connectivity: AppTestConnectivityMonitor(),
            screenCapture: capture
        )
        let notificationCenter = NotificationCenter()
        let refreshed = expectation(description: "Permission refreshed")
        let observation = Task { @MainActor in
            await refreshScreenCapturePermissionOnAppActivation(
                notificationCenter: notificationCenter
            ) {
                model.refreshScreenCapturePermission()
                refreshed.fulfill()
            }
        }
        defer { observation.cancel() }
        await Task.yield()
        capture.permissionGranted = true

        await Task.detached {
            notificationCenter.post(
                name: NSApplication.didBecomeActiveNotification,
                object: nil
            )
        }.value

        await fulfillment(of: [refreshed], timeout: 1)
        XCTAssertTrue(model.screenCaptureGranted)
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

    func testTextOnlyScreenAwareModelFailsBeforeRecordingOrCapture() async throws {
        let suiteName = "ai.dictator.tests.screen-aware-capability.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AppAccessMode.systemWide.rawValue, forKey: "accessMode")
        defaults.set(true, forKey: "screenAwareEnabled")
        defaults.set(ProviderKind.groq.rawValue, forKey: "selectedScreenAwareLLM")
        defaults.set("openai/gpt-oss-20b", forKey: "visionModel.groq")
        let recorder = TestAudioRecorder()
        let capture = TestScreenContextCapture()
        let model = AppModel(
            keychain: ScreenAwareCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
            connectivity: AppTestConnectivityMonitor(),
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
        defaults.set(AppAccessMode.systemWide.rawValue, forKey: "accessMode")
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
            connectivity: AppTestConnectivityMonitor(),
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
        XCTAssertEqual(model.data.lifetimeStatistics.dictations, 1)
        XCTAssertEqual(model.data.lifetimeStatistics.words, 6)
        XCTAssertEqual(model.data.lifetimeStatistics.audioSeconds, 1)
        XCTAssertEqual(model.data.lifetimeStatistics.averageWPM, 360)
        XCTAssertEqual(model.data.lifetimeStatistics.pipelineLatencySamples, 1)
    }
}
