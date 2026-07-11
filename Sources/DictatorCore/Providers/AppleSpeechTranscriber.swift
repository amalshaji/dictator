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

#if canImport(Speech)
import Speech

@available(macOS 26.0, *)
public actor AppleSpeechTranscriber: LocalSpeechTranscribing {
    public init() {}

    public func availableLocales() async -> [AppleSpeechLocale] {
        var locales: [String: AppleSpeechLocale] = [:]
        for locale in await DictationTranscriber.supportedLocales {
            locales[locale.identifier] = .init(identifier: locale.identifier, engine: .dictationTranscriber)
        }
        if SpeechTranscriber.isAvailable {
            for locale in await SpeechTranscriber.supportedLocales {
                locales[locale.identifier] = .init(identifier: locale.identifier, engine: .speechTranscriber)
            }
        }
        return locales.values.sorted { $0.identifier.localizedStandardCompare($1.identifier) == .orderedAscending }
    }

    public func readiness(for localeIdentifier: String) async -> AppleSpeechReadiness {
        guard let resolution = await resolve(localeIdentifier) else {
            return .unavailable("Apple speech transcription does not support this language on this Mac.")
        }
        switch await AssetInventory.status(forModules: [resolution.module]) {
        case .installed:
            return .ready(resolution.locale)
        case .supported, .downloading:
            return .downloadRequired(resolution.locale)
        case .unsupported:
            return .unavailable("The selected Apple speech model is unavailable on this Mac.")
        @unknown default:
            return .unavailable("The Apple speech model reported an unknown availability state.")
        }
    }

    public func installAssets(
        for localeIdentifier: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> AppleSpeechReadiness {
        guard let resolution = await resolve(localeIdentifier) else {
            return .unavailable("Apple speech transcription does not support this language on this Mac.")
        }
        if case .installed = await AssetInventory.status(forModules: [resolution.module]) {
            progress(1)
            return .ready(resolution.locale)
        }
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [resolution.module]) else {
            return await readiness(for: localeIdentifier)
        }

        progress(0)
        let monitor = Task {
            while !Task.isCancelled, request.progress.fractionCompleted < 1 {
                progress(request.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { monitor.cancel() }
        try await request.downloadAndInstall()
        progress(1)

        return await readiness(for: resolution.locale.identifier)
    }

    public func transcribe(
        audio: RecordedAudio,
        localeIdentifier: String,
        vocabulary: [VocabularyEntry]
    ) async throws -> TranscriptionResult {
        guard let resolution = await resolve(localeIdentifier) else {
            throw ProviderError.unsupported("Apple speech transcription does not support this language on this Mac.")
        }
        guard case .installed = await AssetInventory.status(forModules: [resolution.module]) else {
            throw ProviderError.invalidConfiguration("Download the selected Apple speech model before dictating.")
        }

        let started = ContinuousClock.now
        let sourceBuffer = try Self.pcmBuffer(from: audio.wavData)
        let result: String
        switch resolution.locale.engine {
        case .speechTranscriber:
            let transcriber = SpeechTranscriber(locale: resolution.foundationLocale, preset: .transcription)
            result = try await analyze(sourceBuffer, with: transcriber, context: .init())
        case .dictationTranscriber:
            let transcriber = DictationTranscriber(locale: resolution.foundationLocale, preset: .shortDictation)
            let context = AnalysisContext()
            context.contextualStrings[.general] = Array(
                vocabulary.filter(\.isEnabled).map(\.value).filter { !$0.isEmpty }.prefix(100)
            )
            result = try await analyze(sourceBuffer, with: transcriber, context: context)
        }

        let text = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ProviderError.emptyTranscript }
        return TranscriptionResult(
            text: text,
            language: resolution.locale.identifier,
            provider: .appleSpeech,
            model: resolution.locale.engine.rawValue,
            latency: seconds(since: started)
        )
    }

    private struct Resolution {
        let locale: AppleSpeechLocale
        let foundationLocale: Locale
        let module: any SpeechModule
    }

    private func resolve(_ identifier: String) async -> Resolution? {
        let requested = Locale(identifier: identifier)
        if SpeechTranscriber.isAvailable,
           let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) {
            let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
            return Resolution(
                locale: .init(identifier: locale.identifier, engine: .speechTranscriber),
                foundationLocale: locale,
                module: transcriber
            )
        }
        if let locale = await DictationTranscriber.supportedLocale(equivalentTo: requested) {
            let transcriber = DictationTranscriber(locale: locale, preset: .shortDictation)
            return Resolution(
                locale: .init(identifier: locale.identifier, engine: .dictationTranscriber),
                foundationLocale: locale,
                module: transcriber
            )
        }
        return nil
    }

    private func analyze<T: SpeechModule>(
        _ sourceBuffer: AVAudioPCMBuffer,
        with transcriber: T,
        context: AnalysisContext
    ) async throws -> String where T.Result: SpeechTextResult {
        guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw ProviderError.unsupported("No compatible Apple speech audio format is available.")
        }
        let buffer = try Self.convert(sourceBuffer, to: targetFormat)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.setContext(context)
        try await analyzer.prepareToAnalyze(in: targetFormat)

        let resultTask = Task<String, Error> {
            var text = ""
            for try await result in transcriber.results {
                guard result.isFinal else { continue }
                text.append(String(result.transcribedText.characters))
            }
            return text
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
