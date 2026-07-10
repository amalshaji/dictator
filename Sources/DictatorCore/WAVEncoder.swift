import Foundation

public enum WAVEncoder {
    public static func encodePCM16(_ pcm: Data, sampleRate: Int = 16_000, channels: Int = 1) -> Data {
        let byteRate = sampleRate * channels * 2
        let blockAlign = channels * 2
        var output = Data()
        output.appendASCII("RIFF")
        output.appendLE(UInt32(36 + pcm.count))
        output.appendASCII("WAVEfmt ")
        output.appendLE(UInt32(16))
        output.appendLE(UInt16(1))
        output.appendLE(UInt16(channels))
        output.appendLE(UInt32(sampleRate))
        output.appendLE(UInt32(byteRate))
        output.appendLE(UInt16(blockAlign))
        output.appendLE(UInt16(16))
        output.appendASCII("data")
        output.appendLE(UInt32(pcm.count))
        output.append(pcm)
        return output
    }
}

private extension Data {
    mutating func appendASCII(_ string: String) { append(string.data(using: .ascii)!) }
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        append(Data(bytes: &little, count: MemoryLayout<T>.size))
    }
}
