import ComposableArchitecture
import Foundation
import HexCore
import Testing

@testable import Hex

@Suite(.serialized)
@MainActor
struct RealtimeRecordingStartupTests {
	@Test
	func realtimeModeStartsMicInParallelWithSessionConnect() async {
		let now = Date(timeIntervalSince1970: 1_234)
		let probe = StartupProbe()
		var settings = HexSettings()
		settings.transcriptionDeliveryMode = .realtime

		let store = TestStore(
			initialState: TranscriptionFeature.State(
				hexSettings: Shared(settings),
				isRemappingScratchpadFocused: Shared(false),
				transcriptionReadinessState: Shared(.init(isAPIKeyConfigured: true))
			)
		) {
			TranscriptionFeature()
		} withDependencies: {
			$0.date.now = now
			$0.recording.startRecording = {
				await probe.recordMicStart()
			}
			$0.recording.setRealtimeSampleHandler = { _ in
				await probe.recordHandlerInstalled()
			}
			$0.transcription.beginRealtimeSession = { _, _ in
				await probe.recordSessionBegin()
			}
			$0.transcription.waitForRealtimeSessionReady = {
				await probe.recordSessionReadyWaitBegan()
				try await Task.sleep(for: .milliseconds(200))
				await probe.recordSessionReadyWaitFinished()
			}
			$0.transcription.appendRealtimeAudio = { _ in }
			$0.transcription.cancelRealtimeSession = {}
			$0.sleepManagement.preventSleep = { _ in }
			$0.sleepManagement.allowSleep = {}
			$0.soundEffects.play = { _ in }
		}

		await store.send(.startRecording) {
			$0.isRecording = true
			$0.recordingStartTime = now
		}

		await store.finish()

		let events = await probe.events()
		#expect(events.contains(.sessionBegin))
		#expect(events.contains(.handlerInstalled))
		#expect(events.contains(.micStart))
		#expect(events.contains(.sessionReadyWaitBegan))

		guard
			let micIndex = events.firstIndex(of: .micStart),
			let waitFinishedIndex = events.firstIndex(of: .sessionReadyWaitFinished)
		else {
			Issue.record("Expected mic start and session-ready events")
			return
		}

		#expect(micIndex < waitFinishedIndex)
	}

	@Test
	func treatsMissingRealtimePipelineAsEmptyTranscript() {
		#expect(
			TranscriptionFeature.shouldTreatRealtimeStopErrorAsEmptyTranscript(
				RealtimeTranscriptionError.notConnected
			)
		)
		#expect(
			TranscriptionFeature.shouldTreatRealtimeStopErrorAsEmptyTranscript(
				RealtimeTranscriptionError.emptyAudioBuffer
			)
		)
		#expect(
			!TranscriptionFeature.shouldTreatRealtimeStopErrorAsEmptyTranscript(
				RealtimeTranscriptionError.serverError("boom")
			)
		)
	}
}

private actor StartupProbe {
	enum Event: Equatable {
		case sessionBegin
		case handlerInstalled
		case micStart
		case sessionReadyWaitBegan
		case sessionReadyWaitFinished
	}

	private var events: [Event] = []

	func recordSessionBegin() {
		events.append(.sessionBegin)
	}

	func recordHandlerInstalled() {
		events.append(.handlerInstalled)
	}

	func recordMicStart() {
		events.append(.micStart)
	}

	func recordSessionReadyWaitBegan() {
		events.append(.sessionReadyWaitBegan)
	}

	func recordSessionReadyWaitFinished() {
		events.append(.sessionReadyWaitFinished)
	}

	func events() -> [Event] {
		events
	}
}
