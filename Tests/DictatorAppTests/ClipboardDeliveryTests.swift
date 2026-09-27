import AppKit
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

    /// The Home screen's Dictate button activates Dictator's own window, so a
    /// system-wide insertion target captured after that click would be Dictator
    /// itself. `forceClipboardDelivery` must skip target capture even when the
    /// app's insertion mode is `.insert`.
    func testForceClipboardDeliverySkipsFocusedTargetCaptureInInsertMode() async throws {
        let suiteName = "ai.dictator.tests.force-clipboard-delivery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AppAccessMode.systemWide.rawValue, forKey: "accessMode")
        defaults.set(InsertionMode.insert.rawValue, forKey: "insertionMode")

        let recorder = TestAudioRecorder()
        recorder.recordedAudio = .init(wavData: Data([1]), duration: 1)
        let target = ApplicationTarget(
            element: AXUIElementCreateApplication(4242),
            name: "Mail",
            bundleIdentifier: "com.apple.mail",
            processIdentifier: 4242
        )
        let inserter = TestTargetInserter(target: .application(target))
        let clipboardWriter = TestClipboardWriter()
        let transcription = TestTranscriptionCoordinator(result: .init(
            result: .init(text: "Forced to clipboard", provider: .groq, model: "whisper", latency: 0.1),
            usedAppleFallback: false
        ))
        let model = AppModel(
            keychain: AppTestCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
            recorder: recorder,
            transcriptionCoordinator: transcription,
            inserter: inserter,
            clipboardWriter: clipboardWriter
        )

        await model.startDictation(forceClipboardDelivery: true)
        await model.stopDictation()

        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(inserter.captureCount, 0)
        XCTAssertEqual(clipboardWriter.text, "Forced to clipboard")
        XCTAssertNil(inserter.insertedText)
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
        let inserter = TestTargetInserter(target: .application(target))
        let clipboardWriter = TestClipboardWriter()
        let transcription = TestTranscriptionCoordinator(result: .init(
            result: .init(text: "Copied not inserted", provider: .groq, model: "whisper", latency: 0.1),
            usedAppleFallback: false
        ))
        let model = AppModel(
            keychain: AppTestCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
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
        let inserter = TestTargetInserter(target: .application(target))
        let clipboardWriter = TestClipboardWriter()
        let model = AppModel(
            keychain: AppTestCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
            recorder: TestAudioRecorder(),
            inserter: inserter,
            clipboardWriter: clipboardWriter
        )
        model.data.transcripts = [.init(
            rawText: "latest entry", finalText: "latest entry",
            sttProvider: .groq, sttModel: "whisper",
            audioDuration: 1, sttLatency: 0.1, insertionOutcome: "typed"
        )]

        await model.pasteClipboard()

        XCTAssertEqual(clipboardWriter.text, "latest entry")
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
        let inserter = TestTargetInserter(target: .application(target))
        let clipboardWriter = TestClipboardWriter()
        let transcription = TestTranscriptionCoordinator(result: .init(
            result: .init(text: "Keep on clipboard", provider: .groq, model: "whisper", latency: 0.1),
            usedAppleFallback: false
        ))
        let model = AppModel(
            keychain: AppTestCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
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

    func testPasteReturnsBeforeRestoreDelayElapses() async {
        let clipboard = TestClipboard()
        let events = TestEventRecorder()
        let gate = RestoreDelayGate()
        let paster = ClipboardPaster(
            clipboard: clipboard,
            postEvent: { events.post($0) },
            delay: { ms in await gate.delay(ms) }
        )

        let result = await paster.paste("hello")

        XCTAssertTrue(result)
        XCTAssertFalse(clipboard.didRestore, "paste() must not wait for the pasteboard-restore delay")

        await gate.release()
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertTrue(clipboard.didRestore)
        let requested = await gate.requestedDelays
        XCTAssertEqual(requested, [40, 15, 500])
    }

    func testBlockedFocusedTargetKeepsRecordingAndStaysOffSystemPasteboard() async throws {
        let suiteName = "ai.dictator.tests.blocked-target-clipboard.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AppAccessMode.systemWide.rawValue, forKey: "accessMode")

        let recorder = TestAudioRecorder()
        recorder.recordedAudio = .init(wavData: Data([1]), duration: 1)
        let target = ApplicationTarget(
            element: AXUIElementCreateApplication(4242),
            name: "Secure App",
            bundleIdentifier: "com.example.secure",
            processIdentifier: 4242
        )
        let inserter = TestTargetInserter(
            target: .blocked(application: target, reason: "secure fields are never modified")
        )
        let clipboardWriter = TestClipboardWriter()
        let transcription = TestTranscriptionCoordinator(result: .init(
            result: .init(text: "Copied not pasted", provider: .groq, model: "whisper", latency: 0.1),
            usedAppleFallback: false
        ))
        let model = AppModel(
            keychain: AppTestCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
            recorder: recorder,
            transcriptionCoordinator: transcription,
            inserter: inserter,
            clipboardWriter: clipboardWriter
        )

        await model.startDictation()
        XCTAssertEqual(model.phase, .listening, "a blocked target must not abort the recording")

        await model.stopDictation()

        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(inserter.insertedText, "the transcript must never be pasted into a blocked/secure target")
        XCTAssertNil(clipboardWriter.text, "secure-field text must stay off the system pasteboard")
        let record = try XCTUnwrap(model.data.transcripts.first)
        XCTAssertEqual(record.insertionOutcome, InsertionResult.privateClipboard("secure fields are never modified").label)
    }

    func testOverlappingPastesRestoreTheUsersOriginalClipboardContent() async throws {
        let clipboard = SequentialTestClipboard(originalText: "user's original clipboard")
        let events = TestEventRecorder()
        let paster = ClipboardPaster(
            clipboard: clipboard,
            postEvent: { events.post($0) },
            delay: { ms in try? await Task.sleep(for: .milliseconds(ms)) }
        )

        async let first = paster.paste("first dictation")
        try await Task.sleep(for: .milliseconds(100))
        async let second = paster.paste("second dictation")

        let (firstResult, secondResult) = await (first, second)
        XCTAssertTrue(firstResult)
        XCTAssertTrue(secondResult)

        // Both restores fire ~500ms after their own paste; wait past the later one.
        try await Task.sleep(for: .milliseconds(700))

        XCTAssertEqual(clipboard.currentText, "user's original clipboard")
    }

    func testInsertionModePersistsAcrossLaunches() throws {
        let suiteName = "ai.dictator.tests.insertion-mode-persistence.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AppAccessMode.systemWide.rawValue, forKey: "accessMode")

        let first = AppModel(
            keychain: AppTestCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults
        )
        XCTAssertEqual(first.insertionMode, .insert)
        first.setInsertionMode(.clipboard)

        let second = AppModel(
            keychain: AppTestCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults
        )
        XCTAssertEqual(second.insertionMode, .clipboard)
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

/// A `ClipboardAccess` fake that tracks the pasteboard's actual current
/// content across `prepare`/`restore` calls (unlike `TestClipboard`, which
/// only records whether a restore happened), so a test can assert what the
/// pasteboard holds after a sequence of overlapping pastes and restores.
@MainActor
final class SequentialTestClipboard: ClipboardAccess {
    private static let textType = NSPasteboard.PasteboardType("ai.dictator.tests.text")
    private static let sessionType = NSPasteboard.PasteboardType("ai.dictator.tests.session")

    private(set) var currentText: String
    private var currentSessionID: String?

    init(originalText: String) {
        currentText = originalText
    }

    func snapshot() -> PasteboardSnapshot {
        var values: [NSPasteboard.PasteboardType: Data] = [Self.textType: Data(currentText.utf8)]
        if let currentSessionID { values[Self.sessionType] = Data(currentSessionID.utf8) }
        return PasteboardSnapshot(items: [.init(values: values)])
    }

    func prepare(text: String, sessionID: String) -> Bool {
        currentText = text
        currentSessionID = sessionID
        return true
    }

    func owns(text: String, sessionID: String) -> Bool {
        currentText == text && currentSessionID == sessionID
    }

    func restore(_ snapshot: PasteboardSnapshot) {
        guard let item = snapshot.items.first,
              let textData = item.values[Self.textType],
              let text = String(data: textData, encoding: .utf8)
        else { return }
        currentText = text
        currentSessionID = item.values[Self.sessionType].flatMap { String(data: $0, encoding: .utf8) }
    }
}

/// Records every delay `ClipboardPaster` requests. A 500 ms request hangs on
/// a continuation until the test releases it, so the test can prove the
/// pasteboard restore never blocks the awaited `paste(_:)` call.
actor RestoreDelayGate {
    private(set) var requestedDelays: [Int] = []
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func delay(_ ms: Int) async {
        requestedDelays.append(ms)
        guard ms == 500 else { return }
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
