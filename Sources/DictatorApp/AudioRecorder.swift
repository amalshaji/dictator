import AVFoundation
import CoreMedia
import DictatorCore
import Foundation

@MainActor
protocol AudioRecording: AnyObject {
    var onLevel: (@Sendable (Double) -> Void)? { get set }

    func requestPermission() async -> Bool
    func start() throws
    func stop() -> RecordedAudio
    func cancel()
}

@MainActor
protocol AudioCaptureSession: AnyObject {
    var recoveryNotification: Notification.Name { get }
    var recoverySourceIdentifier: ObjectIdentifier { get }

    func start(
        tapHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) throws
    func stop()
}

@MainActor
final class SystemAudioCaptureSession: AudioCaptureSession {
    static let audioSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: true
    ]

    private var session = AVCaptureSession()
    private var output: AVCaptureAudioDataOutput?
    private var outputDelegate: AudioSampleBufferDelegate?
    private let sampleQueue = DispatchQueue(label: "ai.dictator.audio-capture")

    var recoveryNotification: Notification.Name {
        AVCaptureSession.runtimeErrorNotification
    }

    var recoverySourceIdentifier: ObjectIdentifier {
        ObjectIdentifier(session)
    }

    func start(
        tapHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) throws {
        replaceSession()
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
            replaceSession()
            throw AudioRecorderError.captureStartFailed
        }
    }

    func stop() {
        replaceSession()
    }

    private func replaceSession() {
        output?.setSampleBufferDelegate(nil, queue: nil)
        if session.isRunning { session.stopRunning() }
        output = nil
        outputDelegate = nil
        session = AVCaptureSession()
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
    private var isRecording = false
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

    func start() throws {
        buffer.reset()
        recoveryTask?.cancel()
        isRecording = true
        do {
            try session.start(tapHandler: makeTapHandler())
        } catch {
            isRecording = false
            throw error
        }
    }

    func makeTapHandler() -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { [buffer, onLevel] pcm, _ in
            guard let processed = AudioRecorder.process(pcm) else { return }
            onLevel?(processed.normalizedLevel)
            buffer.appendResampled(processed.samples, sourceRate: pcm.format.sampleRate)
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
        endSession()
        let pcm = buffer.data()
        let duration = Double(pcm.count) / 2 / 16_000
        return RecordedAudio(wavData: WAVEncoder.encodePCM16(pcm), duration: duration)
    }

    func cancel() {
        endSession()
        buffer.reset()
    }

    private func recoverAfterRuntimeError() {
        session.stop()
        guard isRecording else { return }
        recoveryTask?.cancel()
        recoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while isRecording, !Task.isCancelled {
                do {
                    try session.start(tapHandler: makeTapHandler())
                    recoveryTask = nil
                    return
                } catch {
                    do { try await Task.sleep(for: .milliseconds(100)) }
                    catch { return }
                }
            }
        }
    }

    private func endSession() {
        isRecording = false
        recoveryTask?.cancel()
        recoveryTask = nil
        session.stop()
    }
}

private final class AudioBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()

    func reset() { lock.withLock { bytes.removeAll(keepingCapacity: true) } }
    func data() -> Data { lock.withLock { bytes } }

    func appendResampled(_ samples: [Float], sourceRate: Double) {
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
        lock.withLock { bytes.append(output) }
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
