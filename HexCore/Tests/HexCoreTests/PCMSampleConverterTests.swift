import Foundation
import Testing
@testable import HexCore

@Test func pcmResamplerProducesExpectedOutputSize() {
  let input = [Float](repeating: 0.5, count: 16_000)
  let output = PCMSampleConverter.float32ToPCM16Resampled(samples: input)

  // 16 kHz -> 24 kHz is a 1.5x sample-rate conversion.
  #expect(output.count == 24_000 * MemoryLayout<Int16>.size)
}

@Test func pcmResamplerEncodesSilenceAsZero() {
  let input = [Float](repeating: 0, count: 100)
  let output = PCMSampleConverter.float32ToPCM16Resampled(
    samples: input,
    sourceSampleRate: 24_000,
    targetSampleRate: 24_000
  )

  #expect(output == Data(repeating: 0, count: 100 * MemoryLayout<Int16>.size))
}
