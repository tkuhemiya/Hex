import Foundation
import Testing
@testable import HexCore

@Test func realtimeWebSocketURLUsesTranscriptionIntentWithoutModelParam() throws {
	let url = RealtimeTranscriptionConfiguration.webSocketURL
	#expect(url.host == "api.openai.com")
	#expect(url.path == "/v1/realtime")

	let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
	#expect(items.contains(where: { $0.name == "intent" && $0.value == "transcription" }))
	#expect(!items.contains(where: { $0.name == "model" }))
}

@Test func sessionUpdatePayloadUsesTranscriptionModelInSessionConfig() throws {
	let payload = RealtimeTranscriptionConfiguration.sessionUpdatePayload(
		transcriptionModel: CloudTranscriptionModel.gpt4oMiniTranscribe.identifier,
		language: "en"
	)

	#expect(payload["type"] as? String == "session.update")

	let session = payload["session"] as? [String: Any]
	#expect(session?["type"] as? String == "transcription")

	let audio = session?["audio"] as? [String: Any]
	let input = audio?["input"] as? [String: Any]
	let transcription = input?["transcription"] as? [String: Any]
	#expect(transcription?["model"] as? String == CloudTranscriptionModel.gpt4oMiniTranscribe.identifier)
	#expect(transcription?["language"] as? String == "en")
	#expect(input?["turn_detection"] is NSNull)

	let format = input?["format"] as? [String: Any]
	#expect(format?["type"] as? String == "audio/pcm")
	#expect(format?["rate"] as? Double == PCMSampleConverter.realtimeSampleRate)
}

@Test func sessionUpdatePayloadOmitsEmptyLanguage() throws {
	let payload = RealtimeTranscriptionConfiguration.sessionUpdatePayload(
		transcriptionModel: CloudTranscriptionModel.gpt4oMiniTranscribe.identifier,
		language: nil
	)

	let session = payload["session"] as? [String: Any]
	let audio = session?["audio"] as? [String: Any]
	let input = audio?["input"] as? [String: Any]
	let transcription = input?["transcription"] as? [String: Any]
	#expect(transcription?["model"] as? String == CloudTranscriptionModel.gpt4oMiniTranscribe.identifier)
	#expect(transcription?["language"] == nil)
}
