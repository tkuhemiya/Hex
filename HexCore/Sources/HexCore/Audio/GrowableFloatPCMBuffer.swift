import Foundation

/// Thread-safe growable buffer for mono float32 PCM samples.
public final class GrowableFloatPCMBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private var samples: [Float] = []

  public init() {}

  public func append(_ newSamples: [Float]) {
    guard !newSamples.isEmpty else { return }
    lock.lock()
    defer { lock.unlock() }
    samples.append(contentsOf: newSamples)
  }

  public func append(_ newSamples: UnsafeBufferPointer<Float>) {
    guard !newSamples.isEmpty else { return }
    lock.lock()
    defer { lock.unlock() }
    samples.append(contentsOf: newSamples)
  }

  public func drain() -> [Float] {
    lock.lock()
    defer { lock.unlock() }
    let drained = samples
    samples = []
    return drained
  }

  public var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return samples.count
  }
}
