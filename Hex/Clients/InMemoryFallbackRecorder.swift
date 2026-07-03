import AVFoundation
import Foundation
import HexCore

/// Fallback in-memory recorder using AVAudioEngine when the primary capture controller cannot start.
final class InMemoryFallbackRecorder {
  private let logger = HexLog.recording
  private let processingQueue = DispatchQueue(label: "com.kitlangton.Hex.InMemoryFallbackRecorder")
  private let meterContinuation: AsyncStream<Meter>.Continuation
  private let targetFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: WAVEncoder.defaultSampleRate,
    channels: 1,
    interleaved: false
  )!

  private var engine: AVAudioEngine?
  private var converter: AVAudioConverter?
  private let samples = GrowableFloatPCMBuffer()
  private var isRecording = false

  init(meterContinuation: AsyncStream<Meter>.Continuation) {
    self.meterContinuation = meterContinuation
  }

  deinit {
    stop()
  }

  var isActive: Bool {
    processingQueue.sync { isRecording }
  }

  func start() throws {
    stop()

    let engine = AVAudioEngine()
    let inputNode = engine.inputNode
    let inputFormat = inputNode.inputFormat(forBus: 0)
    guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
      throw NSError(
        domain: "InMemoryFallbackRecorder",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "Unable to create fallback audio converter."]
      )
    }
    if inputFormat.channelCount > 1 {
      converter.channelMap = [NSNumber(value: 0)]
    }

    self.converter = converter

    inputNode.installTap(onBus: 0, bufferSize: 2_048, format: inputFormat) { [weak self] buffer, _ in
      self?.enqueue(buffer)
    }

    engine.prepare()
    try engine.start()
    self.engine = engine

    processingQueue.sync {
      isRecording = true
    }

    logger.notice("Fallback in-memory recorder started")
  }

  func stop() -> [Float] {
    if let inputNode = engine?.inputNode {
      inputNode.removeTap(onBus: 0)
    }
    engine?.stop()
    engine = nil
    converter = nil

    return processingQueue.sync {
      isRecording = false
      return samples.drain()
    }
  }

  private func enqueue(_ buffer: AVAudioPCMBuffer) {
    guard let copy = clone(buffer) else { return }
    processingQueue.async { [weak self] in
      self?.process(copy)
    }
  }

  private func process(_ buffer: AVAudioPCMBuffer) {
    guard isRecording,
          let converted = convert(buffer),
          converted.frameLength > 0,
          let channelData = converted.floatChannelData?[0]
    else {
      return
    }

    let sampleCount = Int(converted.frameLength)
    samples.append(UnsafeBufferPointer(start: channelData, count: sampleCount))
    meterContinuation.yield(meter(for: channelData, count: sampleCount))
  }

  private func convert(_ inputBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let converter else { return nil }

    let sampleRateRatio = targetFormat.sampleRate / inputBuffer.format.sampleRate
    let frameCapacity = AVAudioFrameCount(
      max(1, (Double(inputBuffer.frameLength) * sampleRateRatio).rounded(.up) + 32)
    )

    guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
      return nil
    }

    var error: NSError?
    var consumedInput = false
    let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
      if consumedInput {
        outStatus.pointee = .noDataNow
        return nil
      }
      consumedInput = true
      outStatus.pointee = .haveData
      return inputBuffer
    }

    if error != nil {
      return nil
    }

    switch status {
    case .haveData, .inputRanDry, .endOfStream:
      return outputBuffer.frameLength > 0 ? outputBuffer : nil
    case .error:
      return nil
    @unknown default:
      return nil
    }
  }

  private func meter(for samples: UnsafePointer<Float>, count: Int) -> Meter {
    guard count > 0 else {
      return Meter(averagePower: 0, peakPower: 0)
    }

    var sumOfSquares: Float = 0
    var peak: Float = 0
    for index in 0 ..< count {
      let sample = samples[index]
      sumOfSquares += sample * sample
      peak = max(peak, abs(sample))
    }

    let rms = sqrt(sumOfSquares / Float(count))
    return Meter(averagePower: Double(rms), peakPower: Double(peak))
  }

  private func clone(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
      return nil
    }

    copy.frameLength = buffer.frameLength

    let sourceBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
    let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    for index in sourceBuffers.indices {
      let source = sourceBuffers[index]
      let destination = destinationBuffers[index]
      guard let sourceData = source.mData, let destinationData = destination.mData else { continue }
      memcpy(destinationData, sourceData, Int(source.mDataByteSize))
      destinationBuffers[index].mDataByteSize = source.mDataByteSize
    }

    return copy
  }
}
