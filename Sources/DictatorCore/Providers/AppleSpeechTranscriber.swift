@preconcurrency import AVFoundation
import Foundation

public protocol LocalSpeechTranscribing: Sendable {
    func availableLocales() async -> [AppleSpeechLocale]
    func readiness(for localeIdentifier: String) async -> AppleSpeechReadiness
    func installAssets(
        for localeIdentifier: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> AppleSpeechReadiness
    func transcribe(
        audio: RecordedAudio,
        localeIdentifier: String,
        vocabulary: [VocabularyEntry]
    ) async throws -> TranscriptionResult
}

@available(macOS 26.0, *)
enum AppleSpeechAssetStatus: Equatable, Sendable {
    case installed
    case supported
    case downloading
    case unsupported
}

@available(macOS 26.0, *)
struct AppleSpeechSegment: Equatable, Sendable {
    let text: String
    let isFinal: Bool
}

@available(macOS 26.0, *)
protocol AppleSpeechRuntime: Sendable {
    func supportedLocaleIdentifiers(for engine: AppleTranscriptionEngine) async -> [String]
    func equivalentLocaleIdentifier(to identifier: String, for engine: AppleTranscriptionEngine) async -> String?
    func assetStatus(for locale: AppleSpeechLocale) async -> AppleSpeechAssetStatus
    func installAssets(for locale: AppleSpeechLocale, progress: @escaping @Sendable (Double) -> Void) async throws
    func transcribe(
        audio: RecordedAudio,
        locale: AppleSpeechLocale,
        vocabulary: [VocabularyEntry]
    ) async throws -> [AppleSpeechSegment]
}

#if canImport(Speech)
import Speech

@available(macOS 26.0, *)
public actor AppleSpeechTranscriber: LocalSpeechTranscribing {
    private let runtime: any AppleSpeechRuntime

    public init() {
        runtime = SystemAppleSpeechRuntime()
    }

    init(runtime: any AppleSpeechRuntime) {
        self.runtime = runtime
    }

    public func availableLocales() async -> [AppleSpeechLocale] {
        var locales: [String: AppleSpeechLocale] = [:]
        for identifier in await runtime.supportedLocaleIdentifiers(for: .dictationTranscriber) {
            locales[identifier] = .init(identifier: identifier, engine: .dictationTranscriber)
        }
        for identifier in await runtime.supportedLocaleIdentifiers(for: .speechTranscriber) {
            locales[identifier] = .init(identifier: identifier, engine: .speechTranscriber)
        }
        return locales.values.sorted { $0.identifier.localizedStandardCompare($1.identifier) == .orderedAscending }
    }

    public func readiness(for localeIdentifier: String) async -> AppleSpeechReadiness {
        let candidates = await candidates(for: localeIdentifier)
        guard !candidates.isEmpty else {
            return .unavailable("Apple speech transcription does not support this language on this Mac.")
        }
        var downloadable: AppleSpeechLocale?
        for candidate in candidates {
            switch await runtime.assetStatus(for: candidate) {
            case .installed: return .ready(candidate)
            case .supported, .downloading: downloadable = downloadable ?? candidate
            case .unsupported: continue
            }
        }
        if let downloadable { return .downloadRequired(downloadable) }
        return .unavailable("The selected Apple speech model is unavailable on this Mac.")
    }

    public func installAssets(
        for localeIdentifier: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> AppleSpeechReadiness {
        let candidates = await candidates(for: localeIdentifier)
        guard !candidates.isEmpty else {
            return .unavailable("Apple speech transcription does not support this language on this Mac.")
        }
        var statuses: [(AppleSpeechLocale, AppleSpeechAssetStatus)] = []
        for candidate in candidates {
            let status = await runtime.assetStatus(for: candidate)
            if status == .installed {
                progress(1)
                return .ready(candidate)
            }
            statuses.append((candidate, status))
        }
        var lastError: Error?
        for (candidate, status) in statuses {
            switch status {
            case .unsupported:
                continue
            case .supported, .downloading:
                do {
                    try await runtime.installAssets(for: candidate, progress: progress)
                    if case .installed = await runtime.assetStatus(for: candidate) {
                        return .ready(candidate)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                }
            case .installed:
                break
            }
        }
        if let lastError { throw lastError }
        return .unavailable("The selected Apple speech model is unavailable on this Mac.")
    }

    public func transcribe(
        audio: RecordedAudio,
        localeIdentifier: String,
        vocabulary: [VocabularyEntry]
    ) async throws -> TranscriptionResult {
        let candidates = await candidates(for: localeIdentifier)
        guard !candidates.isEmpty else {
            throw ProviderError.unsupported("Apple speech transcription does not support this language on this Mac.")
        }
        let started = ContinuousClock.now
        var lastError: Error?
        for candidate in candidates {
            guard await runtime.assetStatus(for: candidate) == .installed else { continue }
            do {
                let segments = try await runtime.transcribe(audio: audio, locale: candidate, vocabulary: vocabulary)
                let text = segments.filter(\.isFinal).map(\.text).joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw ProviderError.emptyTranscript }
                return TranscriptionResult(
                    text: text,
                    language: candidate.identifier,
                    provider: .appleSpeech,
                    model: candidate.engine.rawValue,
                    latency: seconds(since: started)
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        throw ProviderError.invalidConfiguration("Download the selected Apple speech model before dictating.")
    }

    private func candidates(for identifier: String) async -> [AppleSpeechLocale] {
        var candidates: [AppleSpeechLocale] = []
        for engine in [AppleTranscriptionEngine.speechTranscriber, .dictationTranscriber] {
            if let resolved = await runtime.equivalentLocaleIdentifier(to: identifier, for: engine) {
                candidates.append(.init(identifier: resolved, engine: engine))
            }
        }
        return candidates
    }

    static func pcmBuffer(from wav: Data) throws -> AVAudioPCMBuffer {
        guard wav.count >= 44,
              String(data: wav[0..<4], encoding: .ascii) == "RIFF",
              String(data: wav[8..<12], encoding: .ascii) == "WAVE"
        else { throw ProviderError.invalidConfiguration("The recorded audio is not a valid WAV file.") }

        var offset = 12
        var sampleRate: Double?
        var channelCount: UInt16?
        var bitsPerSample: UInt16?
        var formatCode: UInt16?
        var pcmData: Data?
        while offset + 8 <= wav.count {
            let chunkID = String(data: wav[offset..<(offset + 4)], encoding: .ascii)
            let chunkSize = Int(wav.uint32LE(at: offset + 4))
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + chunkSize
            guard payloadEnd <= wav.count else { break }
            if chunkID == "fmt ", chunkSize >= 16 {
                formatCode = wav.uint16LE(at: payloadStart)
                channelCount = wav.uint16LE(at: payloadStart + 2)
                sampleRate = Double(wav.uint32LE(at: payloadStart + 4))
                bitsPerSample = wav.uint16LE(at: payloadStart + 14)
            } else if chunkID == "data" {
                pcmData = wav.subdata(in: payloadStart..<payloadEnd)
            }
            offset = payloadEnd + (chunkSize.isMultiple(of: 2) ? 0 : 1)
        }

        guard formatCode == 1, channelCount == 1, bitsPerSample == 16,
              let sampleRate, sampleRate > 0, let pcmData, !pcmData.isEmpty,
              let format = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
              )
        else { throw ProviderError.unsupported("Apple transcription requires mono 16-bit PCM audio.") }

        let frameCount = AVAudioFrameCount(pcmData.count / MemoryLayout<Int16>.size)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let destination = buffer.int16ChannelData?.pointee
        else { throw ProviderError.invalidConfiguration("Could not allocate an audio buffer.") }
        buffer.frameLength = frameCount
        pcmData.withUnsafeBytes { bytes in
            if let source = bytes.baseAddress { destination.update(from: source.assumingMemoryBound(to: Int16.self), count: Int(frameCount)) }
        }
        return buffer
    }

    static func convert(_ source: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if source.format == format { return source }
        guard let converter = AVAudioConverter(from: source.format, to: format) else {
            throw ProviderError.unsupported("The recording cannot be converted for Apple transcription.")
        }
        let ratio = format.sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(source.frameLength) * ratio)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw ProviderError.invalidConfiguration("Could not allocate a converted audio buffer.")
        }
        let input = ConverterInput(source)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            input.next(status: inputStatus)
        }
        if status == .error {
            throw conversionError ?? ProviderError.invalidConfiguration("Audio conversion failed.")
        }
        return output
    }
}

@available(macOS 26.0, *)
private struct SystemAppleSpeechRuntime: AppleSpeechRuntime {
    func supportedLocaleIdentifiers(for engine: AppleTranscriptionEngine) async -> [String] {
        switch engine {
        case .speechTranscriber:
            guard SpeechTranscriber.isAvailable else { return [] }
            return await SpeechTranscriber.supportedLocales.map(\.identifier)
        case .dictationTranscriber:
            return await DictationTranscriber.supportedLocales.map(\.identifier)
        }
    }

    func equivalentLocaleIdentifier(to identifier: String, for engine: AppleTranscriptionEngine) async -> String? {
        let requested = Locale(identifier: identifier)
        switch engine {
        case .speechTranscriber:
            guard SpeechTranscriber.isAvailable else { return nil }
            return await SpeechTranscriber.supportedLocale(equivalentTo: requested)?.identifier
        case .dictationTranscriber:
            return await DictationTranscriber.supportedLocale(equivalentTo: requested)?.identifier
        }
    }

    func assetStatus(for locale: AppleSpeechLocale) async -> AppleSpeechAssetStatus {
        switch await AssetInventory.status(forModules: [module(for: locale)]) {
        case .installed: .installed
        case .supported: .supported
        case .downloading: .downloading
        case .unsupported: .unsupported
        @unknown default: .unsupported
        }
    }

    func installAssets(
        for locale: AppleSpeechLocale,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let speechModule = module(for: locale)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [speechModule]) else {
            return
        }
        let monitor = Task {
            while !Task.isCancelled, request.progress.fractionCompleted < 1 {
                progress(request.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { monitor.cancel() }
        try await request.downloadAndInstall()
        progress(1)
    }

    func transcribe(
        audio: RecordedAudio,
        locale: AppleSpeechLocale,
        vocabulary: [VocabularyEntry]
    ) async throws -> [AppleSpeechSegment] {
        let sourceBuffer = try AppleSpeechTranscriber.pcmBuffer(from: audio.wavData)
        let foundationLocale = Locale(identifier: locale.identifier)
        switch locale.engine {
        case .speechTranscriber:
            return try await analyze(
                sourceBuffer,
                with: SpeechTranscriber(locale: foundationLocale, preset: .transcription),
                context: .init()
            )
        case .dictationTranscriber:
            let context = AnalysisContext()
            context.contextualStrings[.general] = Array(
                vocabulary.filter(\.isEnabled).map(\.value).filter { !$0.isEmpty }.prefix(100)
            )
            return try await analyze(
                sourceBuffer,
                with: DictationTranscriber(locale: foundationLocale, preset: .shortDictation),
                context: context
            )
        }
    }

    private func module(for locale: AppleSpeechLocale) -> any SpeechModule {
        let foundationLocale = Locale(identifier: locale.identifier)
        return switch locale.engine {
        case .speechTranscriber:
            SpeechTranscriber(locale: foundationLocale, preset: .transcription)
        case .dictationTranscriber:
            DictationTranscriber(locale: foundationLocale, preset: .shortDictation)
        }
    }

    private func analyze<T: SpeechModule>(
        _ sourceBuffer: AVAudioPCMBuffer,
        with transcriber: T,
        context: AnalysisContext
    ) async throws -> [AppleSpeechSegment] where T.Result: SpeechTextResult {
        guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw ProviderError.unsupported("No compatible Apple speech audio format is available.")
        }
        let buffer = try AppleSpeechTranscriber.convert(sourceBuffer, to: targetFormat)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.setContext(context)
        try await analyzer.prepareToAnalyze(in: targetFormat)

        let resultTask = Task<[AppleSpeechSegment], Error> {
            var segments: [AppleSpeechSegment] = []
            for try await result in transcriber.results {
                segments.append(.init(
                    text: String(result.transcribedText.characters),
                    isFinal: result.isFinal
                ))
            }
            return segments
        }
        let input = AsyncStream<AnalyzerInput> { continuation in
            continuation.yield(AnalyzerInput(buffer: buffer))
            continuation.finish()
        }
        do {
            if let lastSample = try await analyzer.analyzeSequence(input) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            return try await resultTask.value
        } catch {
            resultTask.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }
}

private final class ConverterInput: @unchecked Sendable {
    private let source: AVAudioPCMBuffer
    private let lock = NSLock()
    private var supplied = false

    init(_ source: AVAudioPCMBuffer) { self.source = source }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard !supplied else {
            status.pointee = .endOfStream
            return nil
        }
        supplied = true
        status.pointee = .haveData
        return source
    }
}

@available(macOS 26.0, *)
private protocol SpeechTextResult {
    var transcribedText: AttributedString { get }
    var isFinal: Bool { get }
}

@available(macOS 26.0, *)
extension SpeechTranscriber.Result: SpeechTextResult {
    fileprivate var transcribedText: AttributedString { text }
}

@available(macOS 26.0, *)
extension DictationTranscriber.Result: SpeechTextResult {
    fileprivate var transcribedText: AttributedString { text }
}

private extension Data {
    func uint16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func uint32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }
}
#endif
