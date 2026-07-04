import Foundation

/// Holds PCM chunks captured before the Realtime WebSocket session is ready to accept audio.
public struct RealtimeSampleBuffer: Sendable, Equatable {
	private var pendingChunks: [[Float]] = []
	public private(set) var hasAudio = false

	public init() {}

	public mutating func enqueue(_ samples: [Float]) {
		guard !samples.isEmpty else { return }
		hasAudio = true
		pendingChunks.append(samples)
	}

	public mutating func takePending() -> [[Float]] {
		let chunks = pendingChunks
		pendingChunks = []
		return chunks
	}

	public var pendingChunkCount: Int {
		pendingChunks.count
	}
}
