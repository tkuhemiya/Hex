import Foundation

/// OpenAI cloud transcription models supported by this fork.
public enum CloudTranscriptionModel: String, CaseIterable, Sendable {
	case gpt4oMiniTranscribe = "gpt-4o-mini-transcribe-2025-12-15"

	/// The model identifier sent to the OpenAI API.
	public var identifier: String { rawValue }

	public static func isCloud(_ name: String) -> Bool {
		CloudTranscriptionModel(rawValue: name) != nil
	}
}
