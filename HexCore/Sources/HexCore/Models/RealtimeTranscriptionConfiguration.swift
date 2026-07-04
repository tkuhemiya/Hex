import Foundation

/// OpenAI GA Realtime transcription wire format.
///
/// The transcription model (e.g. `gpt-4o-mini-transcribe`) must **not** appear in the
/// WebSocket URL. The URL selects a transcription session via `intent=transcription`;
/// the model is passed in `session.audio.input.transcription.model`.
public enum RealtimeTranscriptionConfiguration {
	public static let webSocketURL = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!

	public static func sessionUpdatePayload(
		transcriptionModel: String,
		language: String?
	) -> [String: Any] {
		var transcription: [String: Any] = ["model": transcriptionModel]
		if let language, !language.isEmpty {
			transcription["language"] = language
		}

		return [
			"type": "session.update",
			"session": [
				"type": "transcription",
				"audio": [
					"input": [
						"format": [
							"type": "audio/pcm",
							"rate": PCMSampleConverter.realtimeSampleRate,
						],
						"transcription": transcription,
						"turn_detection": NSNull(),
					],
				],
			],
		]
	}
}
