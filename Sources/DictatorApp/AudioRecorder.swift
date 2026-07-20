import AVFoundation
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
protocol AudioEngineSession: AnyObject {
    var configurationChangeSource: AnyObject { get }

    func start(
        tapHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) throws
    func stop()
}

@MainActor
private final class SystemAudioEngineSession: AudioEngineSession {
    private let engine = AVAudioEngine()

    var configurationChangeSource: AnyObject { engine }

    func start(
        tapHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioRecorderError.noInput
        }
        input.removeTap(onBus: 0)
        input.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: format,
            block: tapHandler
        )
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

@MainActor
final class AudioRecorder: AudioRecording {
    private let session: any AudioEngineSession
    private let notificationCenter: NotificationCenter
    private let buffer = AudioBuffer()
    private var configurationChangeObserver: NSObjectProtocol?
    private var recoveryTask: Task<Void, Never>?
    private var isRecording = false
    var onLevel: (@Sendable (Double) -> Void)?

    init(
        session: any AudioEngineSession = SystemAudioEngineSession(),
        notificationCenter: NotificationCenter = .default
    ) {
        self.session = session
        self.notificationCenter = notificationCenter
        configurationChangeObserver = notificationCenter.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: session.configurationChangeSource,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recoverAfterConfigurationChange()
            }
        }
    }

    isolated deinit {
        recoveryTask?.cancel()
        if let configurationChangeObserver {
            notificationCenter.removeObserver(configurationChangeObserver)
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

    private func recoverAfterConfigurationChange() {
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
    var errorDescription: String? { "No microphone input is available." }
}
