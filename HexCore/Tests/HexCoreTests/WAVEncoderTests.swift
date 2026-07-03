import XCTest
@testable import HexCore

final class WAVEncoderTests: XCTestCase {
  func testEncodeProducesValidRIFFHeader() {
    let samples: [Float] = [0, 0.5, -0.5, 1.0]
    let wav = WAVEncoder.encode(samples: samples)

    XCTAssertGreaterThanOrEqual(wav.count, 44)
    XCTAssertEqual(String(data: wav[0 ..< 4], encoding: .ascii), "RIFF")
    XCTAssertEqual(String(data: wav[8 ..< 12], encoding: .ascii), "WAVE")
    XCTAssertEqual(String(data: wav[12 ..< 16], encoding: .ascii), "fmt ")
    XCTAssertEqual(String(data: wav[36 ..< 40], encoding: .ascii), "data")

    let dataChunkSize = wav.withUnsafeBytes { rawBuffer -> UInt32 in
      rawBuffer.load(fromByteOffset: 40, as: UInt32.self)
    }
    XCTAssertEqual(Int(dataChunkSize), samples.count * MemoryLayout<Float>.size)
  }

  func testEncodeEmptySamplesProducesHeaderOnly() {
    let wav = WAVEncoder.encode(samples: [])
    XCTAssertEqual(wav.count, 44)
  }
}
