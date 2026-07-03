import Foundation

/// Options passed to the transcription client (cloud OpenAI API).
public struct TranscriptionOptions: Sendable, Equatable {
	public var language: String?

	public init(language: String? = nil) {
		self.language = language
	}
}
