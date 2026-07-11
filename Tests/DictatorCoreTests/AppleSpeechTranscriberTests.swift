@preconcurrency import AVFoundation
import XCTest
@testable import DictatorCore

@available(macOS 26.0, *)
final class AppleSpeechTranscriberTests: XCTestCase {
    private let audio = RecordedAudio(wavData: WAVEncoder.encodePCM16(Data(repeating: 0, count: 3_200)), duration: 0.1)

    func testSpeechTranscriberTakesPrecedenceWhenBothEnginesAreInstalled() async throws {
        let runtime = FakeAppleSpeechRuntime(
            statuses: [.speechTranscriber: .installed, .dictationTranscriber: .installed],
            segments: [.speechTranscriber: [.init(text: "preferred", isFinal: true)]]
        )

        let result = try await AppleSpeechTranscriber(runtime: runtime).transcribe(
            audio: audio,
            localeIdentifier: "en_US",
            vocabulary: []
        )

        XCTAssertEqual(result.text, "preferred")
        XCTAssertEqual(result.model, AppleTranscriptionEngine.speechTranscriber.rawValue)
    }

    func testDictationFallbackRunsWhenSpeechAssetIsUnsupported() async throws {
        let runtime = FakeAppleSpeechRuntime(
            statuses: [.speechTranscriber: .unsupported, .dictationTranscriber: .installed],
            segments: [.dictationTranscriber: [.init(text: "fallback", isFinal: true)]]
        )

        let result = try await AppleSpeechTranscriber(runtime: runtime).transcribe(
            audio: audio,
            localeIdentifier: "en_US",
            vocabulary: []
        )

        XCTAssertEqual(result.text, "fallback")
        XCTAssertEqual(result.model, AppleTranscriptionEngine.dictationTranscriber.rawValue)
    }

    func testReadinessUsesInstalledFallbackBeforeRequiringPreferredAssetDownload() async {
        let runtime = FakeAppleSpeechRuntime(
            statuses: [.speechTranscriber: .supported, .dictationTranscriber: .installed]
        )

        let readiness = await AppleSpeechTranscriber(runtime: runtime).readiness(for: "en_US")

        XCTAssertEqual(readiness, .ready(.init(identifier: "en_US", engine: .dictationTranscriber)))
    }

    func testReadinessReportsUnsupportedOnlyAfterTryingBothEngines() async {
        let runtime = FakeAppleSpeechRuntime(
            statuses: [.speechTranscriber: .unsupported, .dictationTranscriber: .unsupported]
        )

        let readiness = await AppleSpeechTranscriber(runtime: runtime).readiness(for: "en_US")

        guard case .unavailable = readiness else {
            return XCTFail("Expected the locale to be unavailable")
        }
    }

    func testInstallationFallsBackAndReportsProgress() async throws {
        let progress = ProgressRecorder()
        let runtime = FakeAppleSpeechRuntime(
            statuses: [.speechTranscriber: .unsupported, .dictationTranscriber: .supported]
        )

        let readiness = try await AppleSpeechTranscriber(runtime: runtime).installAssets(for: "en_US") { value in
            Task { await progress.append(value) }
        }

        XCTAssertEqual(readiness, .ready(.init(identifier: "en_US", engine: .dictationTranscriber)))
        let values = await progress.values
        XCTAssertEqual(values, [0, 0.5, 1])
    }

    func testOnlyFinalSegmentsAreCombinedInOrder() async throws {
        let runtime = FakeAppleSpeechRuntime(
            statuses: [.speechTranscriber: .installed],
            segments: [.speechTranscriber: [
                .init(text: "draft", isFinal: false),
                .init(text: "first ", isFinal: true),
                .init(text: "second", isFinal: true)
            ]]
        )

        let result = try await AppleSpeechTranscriber(runtime: runtime).transcribe(
            audio: audio,
            localeIdentifier: "en_US",
            vocabulary: []
        )

        XCTAssertEqual(result.text, "first second")
    }

    func testEmptyFinalTranscriptThrows() async {
        let runtime = FakeAppleSpeechRuntime(
            statuses: [.speechTranscriber: .installed],
            segments: [.speechTranscriber: [.init(text: "draft", isFinal: false)]]
        )

        do {
            _ = try await AppleSpeechTranscriber(runtime: runtime).transcribe(
                audio: audio,
                localeIdentifier: "en_US",
                vocabulary: []
            )
            XCTFail("Expected an empty transcript error")
        } catch {
            XCTAssertEqual(error as? ProviderError, .emptyTranscript)
        }
    }

    func testCancellationStopsTranscriptionWithoutTryingFallback() async {
        let runtime = FakeAppleSpeechRuntime(
            statuses: [.speechTranscriber: .installed, .dictationTranscriber: .installed],
            transcriptionDelay: .seconds(10)
        )
        let audio = audio
        let task = Task {
            try await AppleSpeechTranscriber(runtime: runtime).transcribe(
                audio: audio,
                localeIdentifier: "en_US",
                vocabulary: []
            )
        }

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
            let engines = await runtime.transcribedEngines
            XCTAssertEqual(engines, [.speechTranscriber])
        }
    }
}

@available(macOS 26.0, *)
private actor FakeAppleSpeechRuntime: AppleSpeechRuntime {
    private let localeIdentifier = "en_US"
    private var statuses: [AppleTranscriptionEngine: AppleSpeechAssetStatus]
    private let segments: [AppleTranscriptionEngine: [AppleSpeechSegment]]
    private let transcriptionDelay: Duration?
    private(set) var transcribedEngines: [AppleTranscriptionEngine] = []

    init(
        statuses: [AppleTranscriptionEngine: AppleSpeechAssetStatus],
        segments: [AppleTranscriptionEngine: [AppleSpeechSegment]] = [:],
        transcriptionDelay: Duration? = nil
    ) {
        self.statuses = statuses
        self.segments = segments
        self.transcriptionDelay = transcriptionDelay
    }

    func supportedLocaleIdentifiers(for engine: AppleTranscriptionEngine) async -> [String] {
        statuses[engine] == nil ? [] : [localeIdentifier]
    }

    func equivalentLocaleIdentifier(to identifier: String, for engine: AppleTranscriptionEngine) async -> String? {
        statuses[engine] == nil || Locale(identifier: identifier).language.languageCode != .english ? nil : localeIdentifier
    }

    func assetStatus(for locale: AppleSpeechLocale) async -> AppleSpeechAssetStatus {
        statuses[locale.engine] ?? .unsupported
    }

    func installAssets(for locale: AppleSpeechLocale, progress: @escaping @Sendable (Double) -> Void) async throws {
        progress(0)
        progress(0.5)
        statuses[locale.engine] = .installed
        progress(1)
    }

    func transcribe(
        audio: RecordedAudio,
        locale: AppleSpeechLocale,
        vocabulary: [VocabularyEntry]
    ) async throws -> [AppleSpeechSegment] {
        transcribedEngines.append(locale.engine)
        if let transcriptionDelay { try await Task.sleep(for: transcriptionDelay) }
        return segments[locale.engine] ?? []
    }
}

private actor ProgressRecorder {
    private(set) var values: [Double] = []

    func append(_ value: Double) {
        values.append(value)
    }
}
