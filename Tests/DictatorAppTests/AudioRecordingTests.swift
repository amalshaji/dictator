import AVFoundation
import CoreMedia
import Foundation
import XCTest
@testable import Dictator

@MainActor
final class AudioRecordingTests: XCTestCase {
    func testAudioTapHandlerRunsOutsideMainActor() async throws {
        let levels = AudioLevelRecorder()
        let recorder = AudioRecorder()
        recorder.onLevel = { levels.append($0) }
        let tap = recorder.makeTapHandler()

        try await Task.detached {
            let format = try XCTUnwrap(
                AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 2)
            )
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
            pcm.frameLength = 2
            let channels = try XCTUnwrap(pcm.floatChannelData)
            for channel in 0..<2 {
                channels[channel][0] = 0.01
                channels[channel][1] = 0.01
            }

            tap(pcm, AVAudioTime(hostTime: 0))
        }.value

        XCTAssertEqual(try XCTUnwrap(levels.values.first), 0.375, accuracy: 0.001)
    }

    func testDictationShowsListeningStateBeforeAudioCaptureStarts() async throws {
        let suiteName = "ai.dictator.tests.audio-start-feedback.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recorder = TestAudioRecorder()
        var model: AppModel!
        recorder.onStart = {
            XCTAssertEqual(model.phase, .listening)
        }
        model = AppModel(
            keychain: AppTestCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
            connectivity: AppTestConnectivityMonitor(),
            recorder: recorder
        )

        await model.startDictation()

        XCTAssertEqual(model.phase, .listening)
    }

    func testAudioCaptureStartupDoesNotBlockMainActor() async throws {
        let suiteName = "ai.dictator.tests.audio-start-responsiveness.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let gate = AudioStartGate()
        let recorder = TestAudioRecorder()
        recorder.startGate = gate
        let model = AppModel(
            keychain: AppTestCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
            connectivity: AppTestConnectivityMonitor(),
            recorder: recorder
        )
        let startup = Task { @MainActor in await model.startDictation() }
        let responsivenessCheck = Task.detached {
            gate.waitUntilStarted()
            Task { @MainActor in gate.recordMainActorResponse() }
            try? await Task.sleep(for: .milliseconds(100))
            gate.release()
        }

        await responsivenessCheck.value
        await startup.value
        await Task.yield()

        XCTAssertTrue(gate.mainActorRespondedBeforeRelease)
    }

    func testReleaseDuringAudioStartupIgnoresStaleFailure() async throws {
        let suiteName = "ai.dictator.tests.audio-start-release.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let gate = AudioStartGate()
        let recorder = TestAudioRecorder()
        recorder.startGate = gate
        recorder.startError = AudioRecorderError.captureStartFailed
        let model = AppModel(
            keychain: AppTestCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
            connectivity: AppTestConnectivityMonitor(),
            recorder: recorder
        )
        let startup = Task { @MainActor in await model.startDictation() }
        let watchdog = Task.detached {
            gate.waitUntilStarted()
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            gate.release()
        }

        await Task.detached { gate.waitUntilStarted() }.value
        await model.stopDictation()
        gate.release()
        watchdog.cancel()
        await watchdog.value
        await startup.value

        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.lastError)
    }

    func testDictationRestoresIdleStateWhenAudioCaptureFails() async throws {
        let suiteName = "ai.dictator.tests.audio-start-failure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recorder = TestAudioRecorder()
        recorder.startError = AudioRecorderError.captureStartFailed
        let model = AppModel(
            keychain: AppTestCredentialStore(),
            appleSpeechProvider: nil,
            defaults: defaults,
            connectivity: AppTestConnectivityMonitor(),
            recorder: recorder
        )

        await model.startDictation()

        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.lastError, "The microphone could not be started.")
    }

    func testAudioCaptureUsesSelectedDevicePCMFormat() {
        for (sampleRate, channelCount) in [(44_100.0, UInt32(1)), (48_000.0, UInt32(2))] {
            let settings = SystemAudioCaptureSession.audioSettings(
                sampleRate: sampleRate,
                channelCount: channelCount
            )

            XCTAssertEqual(settings[AVFormatIDKey] as? Int, Int(kAudioFormatLinearPCM))
            XCTAssertEqual(settings[AVSampleRateKey] as? Double, sampleRate)
            XCTAssertEqual(settings[AVNumberOfChannelsKey] as? Int, Int(channelCount))
            XCTAssertEqual(settings[AVLinearPCMBitDepthKey] as? Int, 32)
            XCTAssertEqual(settings[AVLinearPCMIsFloatKey] as? Bool, true)
            XCTAssertEqual(settings[AVLinearPCMIsBigEndianKey] as? Bool, false)
            XCTAssertEqual(settings[AVLinearPCMIsNonInterleaved] as? Bool, true)
        }
    }

    func testAudioSampleBufferCopyPopulatesAllocatedFrames() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 1,
            interleaved: false
        ))
        let source = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        source.frameLength = 4
        let samples = try XCTUnwrap(source.floatChannelData?[0])
        for (index, value) in [Float(0.25), -0.5, 0.75, -1].enumerated() {
            samples[index] = value
        }

        var streamDescription = format.streamDescription.pointee
        var formatDescription: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ), noErr)
        let byteCount = Int(source.audioBufferList.pointee.mBuffers.mDataByteSize)
        var blockBuffer: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        ), noErr)
        XCTAssertEqual(CMBlockBufferReplaceDataBytes(
            with: try XCTUnwrap(source.audioBufferList.pointee.mBuffers.mData),
            blockBuffer: try XCTUnwrap(blockBuffer),
            offsetIntoDestination: 0,
            dataLength: byteCount
        ), noErr)
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: try XCTUnwrap(blockBuffer),
            formatDescription: try XCTUnwrap(formatDescription),
            sampleCount: 4,
            presentationTimeStamp: .zero,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        ), noErr)

        let copied = try XCTUnwrap(AudioSampleBufferDelegate.pcmBuffer(
            from: try XCTUnwrap(sampleBuffer)
        ))
        XCTAssertEqual(copied.frameLength, 4)
        XCTAssertEqual(Array(UnsafeBufferPointer(
            start: try XCTUnwrap(copied.floatChannelData?[0]),
            count: 4
        )), [0.25, -0.5, 0.75, -1])
    }

    func testSystemAudioCaptureProducesLiveSamples() async throws {
        guard Bundle.main.bundleIdentifier == "ai.dictator.live-audio-test" else {
            throw XCTSkip("Run with the live-audio test bundle identifier")
        }
        let microphoneGranted = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
        guard microphoneGranted else {
            XCTFail("Microphone permission was not granted to the live-audio test bundle")
            return
        }
        let session = SystemAudioCaptureSession()
        let receivedSample = expectation(description: "Received microphone PCM")
        receivedSample.assertForOverFulfill = false

        try await session.start { pcm, _ in
            if pcm.frameLength > 0 {
                receivedSample.fulfill()
            }
        }
        await fulfillment(of: [receivedSample], timeout: 5)
        await session.stop()
    }

    func testAudioRecorderWaitsForPendingSamplesBeforeFinishing() async throws {
        let session = TestAudioCaptureSession()
        let gate = AudioStartGate()
        session.stopGate = gate
        let recorder = AudioRecorder(
            session: session,
            notificationCenter: NotificationCenter()
        )

        try await recorder.start()
        let stopping = Task { @MainActor in await recorder.stop() }
        await Task.detached { gate.waitUntilStarted() }.value
        gate.release()
        let audio = await stopping.value

        XCTAssertEqual(audio.duration, 0.1, accuracy: 0.001)
    }

    func testAudioRecorderCarriesResamplingStateAcrossCaptureBuffers() async throws {
        let sourceRate = 44_100.0
        let framesPerBuffer = 512
        let bufferCount = 100
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: sourceRate,
            channels: 1
        ))
        let session = TestAudioCaptureSession()
        let recorder = AudioRecorder(
            session: session,
            notificationCenter: NotificationCenter()
        )

        try await recorder.start()
        for _ in 0..<bufferCount {
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(framesPerBuffer)
            ))
            pcm.frameLength = AVAudioFrameCount(framesPerBuffer)
            let samples = try XCTUnwrap(pcm.floatChannelData?[0])
            for index in 0..<framesPerBuffer { samples[index] = 0.1 }
            session.emit(pcm)
        }

        let audio = await recorder.stop()

        XCTAssertEqual(
            audio.duration,
            Double(framesPerBuffer * bufferCount) / sourceRate,
            accuracy: 1 / 16_000
        )
    }

    func testAudioRecorderBandLimitsBeforeDownsampling() async throws {
        let sourceRate = 48_000.0
        let toneFrequency = 12_000.0
        let framesPerBuffer = 512
        let bufferCount = 100
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: sourceRate,
            channels: 1
        ))
        let session = TestAudioCaptureSession()
        let recorder = AudioRecorder(
            session: session,
            notificationCenter: NotificationCenter()
        )

        try await recorder.start()
        for bufferIndex in 0..<bufferCount {
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(framesPerBuffer)
            ))
            pcm.frameLength = AVAudioFrameCount(framesPerBuffer)
            let samples = try XCTUnwrap(pcm.floatChannelData?[0])
            for frame in 0..<framesPerBuffer {
                let sampleIndex = bufferIndex * framesPerBuffer + frame
                let phase = 2 * Double.pi * toneFrequency * Double(sampleIndex) / sourceRate
                samples[frame] = Float(sin(phase))
            }
            session.emit(pcm)
        }

        let audio = await recorder.stop()
        let pcm = Data(audio.wavData.dropFirst(44))
        let samples = pcm.withUnsafeBytes { rawBuffer in
            rawBuffer.bindMemory(to: Int16.self).map { Int16(littleEndian: $0) }
        }
        let meanSquare = samples.reduce(0.0) { result, sample in
            let normalized = Double(sample) / Double(Int16.max)
            return result + normalized * normalized
        } / Double(samples.count)

        XCTAssertLessThan(sqrt(meanSquare), 0.05)
    }

    func testAudioRecorderRestartsAfterCaptureRuntimeError() async throws {
        let notificationCenter = NotificationCenter()
        let session = TestAudioCaptureSession()
        let recorder = AudioRecorder(
            session: session,
            notificationCenter: notificationCenter
        )
        let restarted = expectation(description: "Audio engine restarted")
        session.onStart = {
            if session.startCount == 2 {
                restarted.fulfill()
            }
        }

        try await recorder.start()
        let configurationChangeSource = session.recoverySourceObject
        await Task.detached {
            notificationCenter.post(
                name: session.recoveryNotification,
                object: configurationChangeSource
            )
        }.value

        await fulfillment(of: [restarted], timeout: 1)
        XCTAssertEqual(session.startCount, 2)
        XCTAssertEqual(session.stopCount, 1)
    }

    func testAudioRecorderIgnoresFailureFromSupersededStartup() async throws {
        let notificationCenter = NotificationCenter()
        let session = TestAudioCaptureSession()
        let gate = AudioStartGate()
        session.firstStartGate = gate
        session.startFailuresRemaining = 1
        let recorder = AudioRecorder(
            session: session,
            notificationCenter: notificationCenter
        )
        let firstStartup = Task { @MainActor in try await recorder.start() }
        await Task.detached { gate.waitUntilStarted() }.value
        recorder.cancel()

        try await recorder.start()
        gate.release()
        do {
            try await firstStartup.value
            XCTFail("Expected the superseded startup to fail")
        } catch {}

        let restarted = expectation(description: "Current recording recovered")
        session.onStart = {
            if session.startCount == 3 { restarted.fulfill() }
        }
        notificationCenter.post(
            name: session.recoveryNotification,
            object: session.recoverySourceObject
        )

        await fulfillment(of: [restarted], timeout: 1)
        XCTAssertEqual(session.startCount, 3)
    }

    func testAudioRecorderInvalidatesIdleSessionAfterRuntimeError() async {
        let notificationCenter = NotificationCenter()
        let session = TestAudioCaptureSession()
        let recorder = AudioRecorder(
            session: session,
            notificationCenter: notificationCenter
        )

        notificationCenter.post(
            name: session.recoveryNotification,
            object: session.recoverySourceObject
        )
        await Task.yield()

        XCTAssertEqual(session.stopCount, 1)
        XCTAssertEqual(session.startCount, 0)
        withExtendedLifetime(recorder) {}
    }

    func testAudioRecorderIgnoresRuntimeErrorsFromOtherSessions() async throws {
        let notificationCenter = NotificationCenter()
        let session = TestAudioCaptureSession()
        let recorder = AudioRecorder(
            session: session,
            notificationCenter: notificationCenter
        )

        try await recorder.start()
        notificationCenter.post(
            name: session.recoveryNotification,
            object: TestAudioConfigurationSource()
        )
        await Task.yield()

        XCTAssertEqual(session.startCount, 1)
        XCTAssertEqual(session.stopCount, 0)
    }

    func testAudioRecorderObservesRuntimeErrorsFromReplacementSession() async throws {
        let notificationCenter = NotificationCenter()
        let session = TestAudioCaptureSession()
        let recorder = AudioRecorder(
            session: session,
            notificationCenter: notificationCenter
        )
        let firstRestart = expectation(description: "Audio engine restarted")
        let secondRestart = expectation(description: "Replacement audio engine restarted")
        session.onStart = {
            if session.startCount == 2 {
                firstRestart.fulfill()
            } else if session.startCount == 3 {
                secondRestart.fulfill()
            }
        }

        try await recorder.start()
        notificationCenter.post(
            name: session.recoveryNotification,
            object: session.recoverySourceObject
        )
        await fulfillment(of: [firstRestart], timeout: 1)

        notificationCenter.post(
            name: session.recoveryNotification,
            object: session.recoverySourceObject
        )
        await fulfillment(of: [secondRestart], timeout: 1)

        XCTAssertEqual(session.stopCount, 2)
    }

    func testAudioRecorderRetriesTransientRuntimeRecoveryFailure() async throws {
        let notificationCenter = NotificationCenter()
        let session = TestAudioCaptureSession()
        let recorder = AudioRecorder(
            session: session,
            notificationCenter: notificationCenter
        )
        let restarted = expectation(description: "Audio engine recovered")

        try await recorder.start()
        session.startFailuresRemaining = 1
        session.onStart = {
            if session.startCount == 3 {
                restarted.fulfill()
            }
        }
        notificationCenter.post(
            name: session.recoveryNotification,
            object: session.recoverySourceObject
        )

        await fulfillment(of: [restarted], timeout: 1)
        XCTAssertEqual(session.startCount, 3)
    }

    func testAudioRecorderDoesNotRestartAfterRecordingStops() async throws {
        let notificationCenter = NotificationCenter()
        let session = TestAudioCaptureSession()
        let recorder = AudioRecorder(
            session: session,
            notificationCenter: notificationCenter
        )

        try await recorder.start()
        _ = await recorder.stop()
        notificationCenter.post(
            name: session.recoveryNotification,
            object: session.recoverySourceObject
        )
        await Task.yield()

        XCTAssertEqual(session.startCount, 1)
        XCTAssertEqual(session.stopCount, 2)
    }
}
