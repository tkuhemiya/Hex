import Foundation

/// How recorded audio is delivered to the OpenAI transcription API.
public enum TranscriptionDeliveryMode: String, Codable, CaseIterable, Equatable, Sendable {
	/// Record to memory, then upload the full clip via `/v1/audio/transcriptions`.
	case file
	/// Stream PCM chunks during recording and commit on stop via the Realtime API.
	case realtime

	public var title: String {
		switch self {
		case .file:
			"Upload after recording"
		case .realtime:
			"Stream while recording"
		}
	}

	public var detail: String {
		switch self {
		case .file:
			"Send the full recording when you release the hotkey."
		case .realtime:
			"Send audio while you speak for lower latency. Uses the same model selected above."
		}
	}
}
