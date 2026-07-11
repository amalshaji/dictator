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
