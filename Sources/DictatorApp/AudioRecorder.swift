import AVFoundation
import CoreMedia
import DictatorCore
import Foundation

@MainActor
protocol AudioRecording: AnyObject {
    var onLevel: (@Sendable (Double) -> Void)? { get set }

    func requestPermission() async -> Bool
    func start() async throws
    func stop() async -> RecordedAudio
    func cancel()
}

protocol AudioCaptureSession: AnyObject, Sendable {
    var recoveryNotification: Notification.Name { get }
    var recoverySourceIdentifier: ObjectIdentifier? { get }

    func start(
        tapHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) async throws
    func stop() async
    func cancel()
}

final class SystemAudioCaptureSession: AudioCaptureSession, @unchecked Sendable {
    static func audioSettings(sampleRate: Double, channelCount: UInt32) -> [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channelCount),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
        ]
    }

    // AVCaptureSession and its attachments are accessed only on this queue.
    private let lifecycleQueue = DispatchQueue(label: "ai.dictator.audio-capture.lifecycle")
    private let recoverySourceLock = NSLock()
    private var session: AVCaptureSession?
    private var output: AVCaptureAudioDataOutput?
    private var outputDelegate: AudioSampleBufferDelegate?
    private var currentRecoverySourceIdentifier: ObjectIdentifier?
    private let sampleQueue = DispatchQueue(label: "ai.dictator.audio-capture.samples")

    var recoveryNotification: Notification.Name {
        AVCaptureSession.runtimeErrorNotification
    }

    var recoverySourceIdentifier: ObjectIdentifier? {
        recoverySourceLock.withLock { currentRecoverySourceIdentifier }
    }

    func start(
        tapHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            lifecycleQueue.async { [self] in
                do {
                    try startOnLifecycleQueue(tapHandler: tapHandler)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        setRecoverySourceIdentifier(nil)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lifecycleQueue.async { [self] in
                replaceSessionOnLifecycleQueue()
                sampleQueue.async { continuation.resume() }
            }
        }
    }

    func cancel() {
        setRecoverySourceIdentifier(nil)
        lifecycleQueue.async { [self] in replaceSessionOnLifecycleQueue() }
    }

    private func startOnLifecycleQueue(
        tapHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) throws {
        replaceSessionOnLifecycleQueue()
        let session = AVCaptureSession()
        self.session = session
        setRecoverySourceIdentifier(ObjectIdentifier(session))
        do {
            try configureAndStart(session, tapHandler: tapHandler)
        } catch {
            replaceSessionOnLifecycleQueue()
            throw error
        }
    }

    private func configureAndStart(
        _ session: AVCaptureSession,
        tapHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) throws {
        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw AudioRecorderError.noInput
        }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        guard let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(
            device.activeFormat.formatDescription
        )
        else { throw AudioRecorderError.captureConfigurationFailed }
        output.audioSettings = Self.audioSettings(
            sampleRate: streamDescription.pointee.mSampleRate,
            channelCount: streamDescription.pointee.mChannelsPerFrame
        )
        let outputDelegate = AudioSampleBufferDelegate(tapHandler: tapHandler)
        output.setSampleBufferDelegate(outputDelegate, queue: sampleQueue)

        session.beginConfiguration()
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw AudioRecorderError.captureConfigurationFailed
        }
        session.addInput(input)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw AudioRecorderError.captureConfigurationFailed
        }
        session.addOutput(output)
        session.commitConfiguration()
        self.output = output
        self.outputDelegate = outputDelegate
        session.startRunning()
        guard session.isRunning else {
            throw AudioRecorderError.captureStartFailed
        }
    }

    private func replaceSessionOnLifecycleQueue() {
        output?.setSampleBufferDelegate(nil, queue: nil)
        if session?.isRunning == true { session?.stopRunning() }
        output = nil
        outputDelegate = nil
        session = nil
        setRecoverySourceIdentifier(nil)
    }

    private func setRecoverySourceIdentifier(_ identifier: ObjectIdentifier?) {
        recoverySourceLock.withLock { currentRecoverySourceIdentifier = identifier }
    }
}

final class AudioSampleBufferDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate,
    @unchecked Sendable
{
    private let tapHandler: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void

    init(tapHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        self.tapHandler = tapHandler
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        tapHandler(pcm, AVAudioTime(sampleTime: 0, atRate: pcm.format.sampleRate))
    }

    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0, frameCount <= Int32.max,
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: streamDescription),
              format.commonFormat == .pcmFormatFloat32,
              let pcm = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
              )
        else { return nil }
        pcm.frameLength = AVAudioFrameCount(frameCount)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcm.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        return pcm
    }
}

@MainActor
final class AudioRecorder: AudioRecording {
    private let session: any AudioCaptureSession
    private let notificationCenter: NotificationCenter
    private let buffer = AudioBuffer()
    private var recoveryObserver: NSObjectProtocol?
    private var recoveryTask: Task<Void, Never>?
    private var activeRecordingID: UUID?
    var onLevel: (@Sendable (Double) -> Void)?

    init(
        session: any AudioCaptureSession = SystemAudioCaptureSession(),
        notificationCenter: NotificationCenter = .default
    ) {
        self.session = session
        self.notificationCenter = notificationCenter
        recoveryObserver = notificationCenter.addObserver(
            forName: session.recoveryNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let source = notification.object else { return }
            let sourceIdentifier = ObjectIdentifier(source as AnyObject)
            Task { @MainActor [weak self] in
                guard let self,
                      self.session.recoverySourceIdentifier == sourceIdentifier
                else { return }
                self.recoverAfterRuntimeError()
            }
        }
    }

    isolated deinit {
        recoveryTask?.cancel()
        if let recoveryObserver {
            notificationCenter.removeObserver(recoveryObserver)
        }
    }

    func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start() async throws {
        let recordingID = UUID()
        buffer.begin(recordingID)
        recoveryTask?.cancel()
        activeRecordingID = recordingID
        do {
            try await session.start(tapHandler: makeTapHandler(recordingID: recordingID))
        } catch {
            if activeRecordingID == recordingID {
                activeRecordingID = nil
                buffer.cancel(recordingID)
            }
            throw error
        }
    }

    func makeTapHandler(
        recordingID: UUID? = nil
    ) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { [buffer, onLevel] pcm, _ in
            guard let processed = AudioRecorder.process(pcm) else { return }
            guard buffer.appendResampled(
                processed.samples,
                sourceRate: pcm.format.sampleRate,
                recordingID: recordingID
            ) else { return }
            onLevel?(processed.normalizedLevel)
        }
    }

    nonisolated private static func process(
        _ pcm: AVAudioPCMBuffer
    ) -> (samples: [Float], normalizedLevel: Double)? {
        guard let channels = pcm.floatChannelData else { return nil }
        let frames = Int(pcm.frameLength)
        let channelCount = Int(pcm.format.channelCount)
        guard frames > 0, channelCount > 0 else { return nil }
        var mono = [Float](repeating: 0, count: frames)
        for channel in 0..<channelCount {
            for frame in 0..<frames { mono[frame] += channels[channel][frame] / Float(channelCount) }
        }
        let rms = sqrt(mono.reduce(0) { $0 + $1 * $1 } / Float(frames))
        let decibels = 20 * log10(max(Double(rms), 0.000_01))
        let normalizedLevel = max(0, min(1, (decibels + 55) / 40))
        return (mono, normalizedLevel)
    }

    func stop() async -> RecordedAudio {
        let recordingID = endSession()
        await session.stop()
        let pcm = recordingID.map(buffer.finish) ?? Data()
        let duration = Double(pcm.count) / 2 / 16_000
        return RecordedAudio(wavData: WAVEncoder.encodePCM16(pcm), duration: duration)
    }

    func cancel() {
        let recordingID = endSession()
        session.cancel()
        if let recordingID {
            buffer.cancel(recordingID)
        }
    }

    private func recoverAfterRuntimeError() {
        guard let recordingID = activeRecordingID else {
            session.cancel()
            return
        }
        recoveryTask?.cancel()
        recoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await session.stop()
            while activeRecordingID == recordingID, !Task.isCancelled {
                do {
                    try await session.start(tapHandler: makeTapHandler(recordingID: recordingID))
                    guard activeRecordingID == recordingID else { return }
                    recoveryTask = nil
                    return
                } catch {
                    do { try await Task.sleep(for: .milliseconds(100)) }
                    catch { return }
                }
            }
        }
    }

    private func endSession() -> UUID? {
        let recordingID = activeRecordingID
        activeRecordingID = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        return recordingID
    }
}

private final class AudioBuffer: @unchecked Sendable {
    private static let outputSampleRate = 16_000.0
    private static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: outputSampleRate,
        channels: 1,
        interleaved: false
    )!

    private let lock = NSLock()
    private var bytes = Data()
    private var activeRecordingID: UUID?
    private var converter: AVAudioConverter?
    private var converterSourceRate: Double?

    func begin(_ recordingID: UUID) {
        lock.withLock {
            activeRecordingID = recordingID
            bytes.removeAll(keepingCapacity: true)
            resetConverter()
        }
    }

    func finish(_ recordingID: UUID) -> Data {
        lock.withLock {
            guard activeRecordingID == recordingID else { return Data() }
            _ = finishConversion()
            activeRecordingID = nil
            resetConverter()
            return bytes
        }
    }

    func cancel(_ recordingID: UUID) {
        lock.withLock {
            guard activeRecordingID == recordingID else { return }
            activeRecordingID = nil
            bytes.removeAll(keepingCapacity: true)
            resetConverter()
        }
    }

    func appendResampled(
        _ samples: [Float],
        sourceRate: Double,
        recordingID: UUID?
    ) -> Bool {
        lock.withLock {
            guard recordingID == nil || activeRecordingID == recordingID else { return false }
            guard prepareConverter(sourceRate: sourceRate),
                  let input = Self.inputBuffer(samples: samples, sampleRate: sourceRate),
                  let output = convert(input)
            else { return false }
            bytes.append(output)
            return true
        }
    }

    private func prepareConverter(sourceRate: Double) -> Bool {
        if converterSourceRate == sourceRate, converter != nil { return true }
        if converter != nil { _ = finishConversion() }
        resetConverter()
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: Self.outputFormat)
        else { return false }
        converter.primeMethod = .normal
        self.converter = converter
        converterSourceRate = sourceRate
        return true
    }

    private func convert(_ input: AVAudioPCMBuffer) -> Data? {
        guard let converter else { return nil }
        let outputFrameCapacity = AVAudioFrameCount(ceil(
            Double(input.frameLength) * Self.outputSampleRate / input.format.sampleRate
        )) + 1
        guard let output = AVAudioPCMBuffer(
            pcmFormat: Self.outputFormat,
            frameCapacity: outputFrameCapacity
        ) else { return nil }
        let inputProvider = AudioConverterInputProvider(input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            inputProvider.next(status: inputStatus)
        }
        guard status != .error, conversionError == nil else { return nil }
        return Self.pcm16Data(from: output)
    }

    private func finishConversion() -> Bool {
        guard let converter, let sourceRate = converterSourceRate else { return true }
        let trailingFrames = Double(converter.primeInfo.trailingFrames)
        let outputFrameCapacity = max(1, AVAudioFrameCount(ceil(
            trailingFrames * Self.outputSampleRate / sourceRate
        )) + 1)
        while true {
            guard let output = AVAudioPCMBuffer(
                pcmFormat: Self.outputFormat,
                frameCapacity: outputFrameCapacity
            ) else { return false }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            guard status != .error, conversionError == nil,
                  let outputData = Self.pcm16Data(from: output)
            else { return false }
            bytes.append(outputData)
            if status == .endOfStream { return true }
            if output.frameLength == 0 { return false }
        }
    }

    private func resetConverter() {
        converter?.reset()
        converter = nil
        converterSourceRate = nil
    }

    private static func inputBuffer(samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ), let input = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ), let channel = input.floatChannelData?[0]
        else { return nil }
        input.frameLength = AVAudioFrameCount(samples.count)
        for index in samples.indices { channel[index] = samples[index] }
        return input
    }

    private static func pcm16Data(from buffer: AVAudioPCMBuffer) -> Data? {
        guard buffer.frameLength > 0 else { return Data() }
        guard let channel = buffer.int16ChannelData?[0] else { return nil }
        return Data(bytes: channel, count: Int(buffer.frameLength) * MemoryLayout<Int16>.size)
    }
}

private final class AudioConverterInputProvider: @unchecked Sendable {
    private let lock = NSLock()
    private let input: AVAudioPCMBuffer
    private var suppliedInput = false

    init(_ input: AVAudioPCMBuffer) {
        self.input = input
    }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.withLock {
            guard !suppliedInput else {
                status.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            status.pointee = .haveData
            return input
        }
    }
}

enum AudioRecorderError: LocalizedError {
    case noInput
    case captureConfigurationFailed
    case captureStartFailed

    var errorDescription: String? {
        switch self {
        case .noInput: "No microphone input is available."
        case .captureConfigurationFailed: "The microphone could not be configured."
        case .captureStartFailed: "The microphone could not be started."
        }
    }
}
