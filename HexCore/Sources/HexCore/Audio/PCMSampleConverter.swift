import Foundation

public enum PCMSampleConverter {
  /// Sample rate expected by the OpenAI Realtime transcription API for `pcm16` / `audio/pcm`.
  public static let realtimeSampleRate: Double = 24_000

  /// Resamples mono float32 PCM and encodes little-endian PCM16.
  public static func float32ToPCM16Resampled(
    samples: [Float],
    sourceSampleRate: Double = WAVEncoder.defaultSampleRate,
    targetSampleRate: Double = realtimeSampleRate
  ) -> Data {
    guard !samples.isEmpty else { return Data() }

    if sourceSampleRate == targetSampleRate {
      return encodePCM16(samples)
    }

    let ratio = targetSampleRate / sourceSampleRate
    let outputCount = max(1, Int((Double(samples.count) * ratio).rounded(.up)))
    var output = [Int16]()
    output.reserveCapacity(outputCount)

    for outputIndex in 0 ..< outputCount {
      let sourcePosition = Double(outputIndex) / ratio
      let lowerIndex = Int(sourcePosition.rounded(.down))
      let upperIndex = min(lowerIndex + 1, samples.count - 1)
      let fraction = Float(sourcePosition - Double(lowerIndex))
      let interpolated = samples[lowerIndex] * (1 - fraction) + samples[upperIndex] * fraction
      output.append(quantize(interpolated))
    }

    return output.withUnsafeBufferPointer { buffer in
      Data(buffer: buffer)
    }
  }

  private static func encodePCM16(_ samples: [Float]) -> Data {
    var output = [Int16]()
    output.reserveCapacity(samples.count)
    for sample in samples {
      output.append(quantize(sample))
    }
    return output.withUnsafeBufferPointer { buffer in
      Data(buffer: buffer)
    }
  }

  private static func quantize(_ sample: Float) -> Int16 {
    let clamped = min(max(sample, -1), 1)
    return Int16((clamped * Float(Int16.max)).rounded())
  }
}
