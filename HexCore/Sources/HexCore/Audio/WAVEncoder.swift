import Foundation

public enum WAVEncoder {
  public static let defaultSampleRate: Double = 16_000

  /// Encodes mono 32-bit IEEE float PCM samples into a WAV container.
  public static func encode(
    samples: [Float],
    sampleRate: Double = defaultSampleRate
  ) -> Data {
    let channels: UInt16 = 1
    let bitsPerSample: UInt16 = 32
    let audioFormat: UInt16 = 3 // IEEE float
    let blockAlign = channels * bitsPerSample / 8
    let byteRate = UInt32(sampleRate) * UInt32(blockAlign)
    let dataSize = UInt32(samples.count * MemoryLayout<Float>.size)

    var data = Data()
    data.reserveCapacity(44 + Int(dataSize))

    func appendUInt32(_ value: UInt32) {
      var littleEndian = value.littleEndian
      withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    func appendUInt16(_ value: UInt16) {
      var littleEndian = value.littleEndian
      withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    data.append(contentsOf: "RIFF".utf8)
    appendUInt32(36 + dataSize)
    data.append(contentsOf: "WAVE".utf8)
    data.append(contentsOf: "fmt ".utf8)
    appendUInt32(16)
    appendUInt16(audioFormat)
    appendUInt16(channels)
    appendUInt32(UInt32(sampleRate))
    appendUInt32(byteRate)
    appendUInt16(blockAlign)
    appendUInt16(bitsPerSample)
    data.append(contentsOf: "data".utf8)
    appendUInt32(dataSize)

    samples.withUnsafeBufferPointer { buffer in
      guard let baseAddress = buffer.baseAddress else { return }
      let byteCount = buffer.count * MemoryLayout<Float>.size
      data.append(contentsOf: UnsafeRawBufferPointer(start: baseAddress, count: byteCount))
    }

    return data
  }
}
