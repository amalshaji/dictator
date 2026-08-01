import AVFoundation
import CoreMedia
import DictatorCore
import Foundation

@MainActor
protocol AudioRecording: AnyObject {
    var onLevel: (@Sendable (Double) -> Void)? { get set }

    func requestPermission() async -> Bool
    func start() async throws
    func stop() -> RecordedAudio
    func cancel()
}

protocol AudioCaptureSession: AnyObject, Sendable {
    var recoveryNotification: Notification.Name { get }
    var recoverySourceIdentifier: ObjectIdentifier? { get }

    func start(
        tapHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) async throws
    func stop()
}

final class SystemAudioCaptureSession: AudioCaptureSession, @unchecked Sendable {
    static var audioSettings: [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true
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

    func stop() {
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
        output.audioSettings = Self.audioSettings
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

private final class AudioSampleBufferDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate,
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

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
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
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcm.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        pcm.frameLength = AVAudioFrameCount(frameCount)
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

    func stop() -> RecordedAudio {
        let recordingID = endSession()
        let pcm = recordingID.map(buffer.finish) ?? Data()
        let duration = Double(pcm.count) / 2 / 16_000
        return RecordedAudio(wavData: WAVEncoder.encodePCM16(pcm), duration: duration)
    }

    func cancel() {
        if let recordingID = endSession() {
            buffer.cancel(recordingID)
        }
    }

    private func recoverAfterRuntimeError() {
        session.stop()
        guard let recordingID = activeRecordingID else { return }
        recoveryTask?.cancel()
        recoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
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
        session.stop()
        return recordingID
    }
}

private final class AudioBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var activeRecordingID: UUID?

    func begin(_ recordingID: UUID) {
        lock.withLock {
            activeRecordingID = recordingID
            bytes.removeAll(keepingCapacity: true)
        }
    }

    func finish(_ recordingID: UUID) -> Data {
        lock.withLock {
            guard activeRecordingID == recordingID else { return Data() }
            activeRecordingID = nil
            return bytes
        }
    }

    func cancel(_ recordingID: UUID) {
        lock.withLock {
            guard activeRecordingID == recordingID else { return }
            activeRecordingID = nil
            bytes.removeAll(keepingCapacity: true)
        }
    }

    func appendResampled(
        _ samples: [Float],
        sourceRate: Double,
        recordingID: UUID?
    ) -> Bool {
        let ratio = sourceRate / 16_000
        let outputCount = max(1, Int(Double(samples.count) / ratio))
        var output = Data(capacity: outputCount * 2)
        for index in 0..<outputCount {
            let position = min(Double(samples.count - 1), Double(index) * ratio)
            let lower = Int(position)
            let upper = min(samples.count - 1, lower + 1)
            let fraction = Float(position - Double(lower))
            let sample = samples[lower] + (samples[upper] - samples[lower]) * fraction
            var value = Int16(max(-1, min(1, sample)) * Float(Int16.max)).littleEndian
            output.append(Data(bytes: &value, count: 2))
        }
        return lock.withLock {
            guard recordingID == nil || activeRecordingID == recordingID else { return false }
            bytes.append(output)
            return true
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
