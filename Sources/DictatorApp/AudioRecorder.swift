import AVFoundation
import DictatorCore
import Foundation

final class AudioRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let buffer = AudioBuffer()
    private var startedAt: ContinuousClock.Instant?
    var onLevel: (@Sendable (Double) -> Void)?

    func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start() throws {
        buffer.reset()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioRecorderError.noInput }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [buffer, onLevel] pcm, _ in
            guard let channels = pcm.floatChannelData else { return }
            let frames = Int(pcm.frameLength)
            let channelCount = Int(pcm.format.channelCount)
            guard frames > 0 else { return }
            var mono = [Float](repeating: 0, count: frames)
            for channel in 0..<channelCount {
                for frame in 0..<frames { mono[frame] += channels[channel][frame] / Float(channelCount) }
            }
            let rms = sqrt(mono.reduce(0) { $0 + $1 * $1 } / Float(frames))
            let decibels = 20 * log10(max(Double(rms), 0.000_01))
            let normalizedLevel = max(0, min(1, (decibels + 55) / 40))
            onLevel?(normalizedLevel)
            buffer.appendResampled(mono, sourceRate: pcm.format.sampleRate)
        }
        engine.prepare()
        try engine.start()
        startedAt = .now
    }

    func stop() -> RecordedAudio {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let pcm = buffer.data()
        let duration = Double(pcm.count) / 2 / 16_000
        startedAt = nil
        return RecordedAudio(wavData: WAVEncoder.encodePCM16(pcm), pcm16Data: pcm, duration: duration)
    }

    func cancel() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        buffer.reset()
        startedAt = nil
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
