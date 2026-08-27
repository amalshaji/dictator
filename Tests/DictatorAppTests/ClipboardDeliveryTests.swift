import CoreGraphics
import DictatorCore
import Foundation
import XCTest
@testable import Dictator

@MainActor
final class ClipboardDeliveryTests: XCTestCase {
    func testMissingFocusedTargetNeverTouchesAnotherApp() async {
        let result = await AccessibilityInserter().insert(.dictation("private text"), into: nil)
        XCTAssertEqual(result, .privateClipboard("no editable field was focused"))
    }

    func testLeastPrivilegesCopiesResultWithoutCapturingFocusedTarget() async throws {
        let suiteName = "ai.dictator.tests.clipboard-mode.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(InsertionMode.clipboard.rawValue, forKey: "insertionMode")

        let recorder = TestAudioRecorder()
        recorder.recordedAudio = .init(wavData: Data([1]), duration: 1)
        let target = ApplicationTarget(
            element: AXUIElementCreateApplication(4242),
            name: "Mail",
            bundleIdentifier: "com.apple.mail",
            processIdentifier: 4242
        )
        let window = FocusedWindowSnapshot(
            processIdentifier: 4242,
            applicationName: "Mail",
            bundleIdentifier: "com.apple.mail",
            title: "Reply",
            frame: CGRect(x: 10, y: 10, width: 800, height: 600)
        )
        let inserter = TestTargetInserter(target: .application(target), window: window)
        let clipboardWriter = TestClipboardWriter()
        let transcription = TestTranscriptionCoordinator(result: .init(
            result: .init(text: "Copied not inserted", provider: .groq, model: "whisper", latency: 0.1),
            mode: .online
        ))
        let model = AppModel(
            keychain: AppTestCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
            connectivity: AppTestConnectivityMonitor(),
            recorder: recorder,
            transcriptionCoordinator: transcription,
            inserter: inserter,
            clipboardWriter: clipboardWriter
        )

        await model.startDictation()
        await model.stopDictation()

        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(inserter.captureCount, 0)
        XCTAssertEqual(clipboardWriter.text, "Copied not inserted")
        XCTAssertNil(inserter.insertedText)
        XCTAssertEqual(model.data.clipboard.first?.text, "Copied not inserted")
        let record = try XCTUnwrap(model.data.transcripts.first)
        XCTAssertEqual(record.insertionOutcome, InsertionResult.copiedToClipboard.label)
    }

    func testClipboardModePasteLatestCopiesInsteadOfPosting() async throws {
        let suiteName = "ai.dictator.tests.clipboard-mode-paste-latest.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(InsertionMode.clipboard.rawValue, forKey: "insertionMode")

        let target = ApplicationTarget(
            element: AXUIElementCreateApplication(4242),
            name: "Mail",
            bundleIdentifier: "com.apple.mail",
            processIdentifier: 4242
        )
        let window = FocusedWindowSnapshot(
            processIdentifier: 4242,
            applicationName: "Mail",
            bundleIdentifier: "com.apple.mail",
            title: "Reply",
            frame: CGRect(x: 10, y: 10, width: 800, height: 600)
        )
        let inserter = TestTargetInserter(target: .application(target), window: window)
        let clipboardWriter = TestClipboardWriter()
        let model = AppModel(
            keychain: AppTestCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
            connectivity: AppTestConnectivityMonitor(),
            recorder: TestAudioRecorder(),
            inserter: inserter,
            clipboardWriter: clipboardWriter
        )
        model.data.clipboard = [.init(text: "latest entry", rawText: "latest entry", sourceBundleID: nil)]

        await model.pasteClipboard()
        await model.pasteTranscriptText("transcript text")

        XCTAssertEqual(clipboardWriter.text, "transcript text")
        XCTAssertNil(inserter.pastedText)
    }

    func testRecordingKeepsClipboardDeliveryWhenSettingChangesMidRun() async throws {
        let suiteName = "ai.dictator.tests.clipboard-delivery-snapshot.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AppAccessMode.systemWide.rawValue, forKey: "accessMode")
        defaults.set(InsertionMode.clipboard.rawValue, forKey: "insertionMode")
        let recorder = TestAudioRecorder()
        recorder.recordedAudio = .init(wavData: Data([1]), duration: 1)
        let target = ApplicationTarget(
            element: AXUIElementCreateApplication(4242),
            name: "Mail",
            bundleIdentifier: "com.apple.mail",
            processIdentifier: 4242
        )
        let window = FocusedWindowSnapshot(
            processIdentifier: 4242,
            applicationName: "Mail",
            bundleIdentifier: "com.apple.mail",
            title: "Reply",
            frame: CGRect(x: 10, y: 10, width: 800, height: 600)
        )
        let inserter = TestTargetInserter(target: .application(target), window: window)
        let clipboardWriter = TestClipboardWriter()
        let transcription = TestTranscriptionCoordinator(result: .init(
            result: .init(text: "Keep on clipboard", provider: .groq, model: "whisper", latency: 0.1),
            mode: .online
        ))
        let model = AppModel(
            keychain: AppTestCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
            connectivity: AppTestConnectivityMonitor(),
            recorder: recorder,
            transcriptionCoordinator: transcription,
            inserter: inserter,
            clipboardWriter: clipboardWriter
        )

        await model.startDictation()
        model.setInsertionMode(.insert)
        await model.stopDictation()

        XCTAssertEqual(clipboardWriter.text, "Keep on clipboard")
        XCTAssertNil(inserter.insertedText)
    }

    func testInsertionModePersistsAcrossLaunches() throws {
        let suiteName = "ai.dictator.tests.insertion-mode-persistence.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AppAccessMode.systemWide.rawValue, forKey: "accessMode")

        let first = AppModel(
            keychain: AppTestCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
            connectivity: AppTestConnectivityMonitor()
        )
        XCTAssertEqual(first.insertionMode, .insert)
        first.setInsertionMode(.clipboard)

        let second = AppModel(
            keychain: AppTestCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
            connectivity: AppTestConnectivityMonitor()
        )
        XCTAssertEqual(second.insertionMode, .clipboard)
    }
}
