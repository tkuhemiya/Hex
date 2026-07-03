import Foundation

/// In-memory audio captured from the microphone, encoded as WAV bytes.
public struct CapturedAudio: Sendable, Equatable {
  public let wavData: Data
  public let duration: TimeInterval

  public init(wavData: Data, duration: TimeInterval) {
    self.wavData = wavData
    self.duration = duration
  }

  public static let empty = CapturedAudio(wavData: Data(), duration: 0)

  public var isEmpty: Bool {
    wavData.isEmpty
  }
}
