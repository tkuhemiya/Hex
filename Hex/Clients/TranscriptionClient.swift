//
//  TranscriptionClient.swift
//  Hex
//

import Dependencies
import DependenciesMacros
import Foundation
import HexCore

private let transcriptionLogger = HexLog.transcription

/// Transcribes audio via the OpenAI cloud API.
@DependencyClient
struct TranscriptionClient {
	var transcribe: @Sendable (Data, String, TranscriptionOptions, @escaping (Progress) -> Void) async throws -> String
	var isReady: @Sendable () async -> Bool = { false }
	var beginRealtimeSession: @Sendable (String, TranscriptionOptions) async throws -> Void = { _, _ in }
	var waitForRealtimeSessionReady: @Sendable () async throws -> Void = {}
	var appendRealtimeAudio: @Sendable ([Float]) async -> Void = { _ in }
	var finishRealtimeSession: @Sendable () async throws -> String = { "" }
	var cancelRealtimeSession: @Sendable () async -> Void = {}
}

extension TranscriptionClient: DependencyKey {
	static var liveValue: Self {
		let live = TranscriptionClientLive()
		return Self(
			transcribe: { try await live.transcribe(audioData: $0, model: $1, options: $2, progressCallback: $3) },
			isReady: { await live.isReady() },
			beginRealtimeSession: { try await live.beginRealtimeSession(model: $0, options: $1) },
			waitForRealtimeSessionReady: { try await live.waitForRealtimeSessionReady() },
			appendRealtimeAudio: { await live.appendRealtimeAudio(samples: $0) },
			finishRealtimeSession: { try await live.finishRealtimeSession() },
			cancelRealtimeSession: { await live.cancelRealtimeSession() }
		)
	}

	static let testValue = Self(
		transcribe: { _, _, _, _ in "" },
		isReady: { true },
		beginRealtimeSession: { _, _ in },
		waitForRealtimeSessionReady: {},
		appendRealtimeAudio: { _ in },
		finishRealtimeSession: { "" },
		cancelRealtimeSession: {}
	)
}

extension DependencyValues {
	var transcription: TranscriptionClient {
		get { self[TranscriptionClient.self] }
		set { self[TranscriptionClient.self] = newValue }
	}
}

struct TranscriptionClientLive: Sendable {
	private let realtimeCoordinator = RealtimeTranscriptionCoordinator()

	func isReady() async -> Bool {
		guard let key = APIKeyClient.liveValue.getOpenAIKey(), !key.isEmpty else {
			return false
		}
		return true
	}

	func transcribe(
		audioData: Data,
		model: String,
		options: TranscriptionOptions,
		progressCallback: @escaping (Progress) -> Void
	) async throws -> String {
		guard CloudTranscriptionModel.isCloud(model) else {
			throw TranscriptionClientError.unsupportedModel(model)
		}

		let progress = Progress(totalUnitCount: 100)
		progress.completedUnitCount = 0
		progressCallback(progress)

		let startAll = Date()
		transcriptionLogger.notice("Transcribing with cloud model=\(model) bytes=\(audioData.count)")

		let apiKey = APIKeyClient.liveValue.getOpenAIKey()
		let startTx = Date()
		let text = try await OpenAITranscriptionClient().transcribe(
			audioData: audioData,
			filename: "recording.wav",
			model: model,
			language: options.language,
			apiKey: apiKey
		)

		progress.completedUnitCount = 100
		progressCallback(progress)

		transcriptionLogger.info("Cloud transcription took \(String(format: "%.2f", Date().timeIntervalSince(startTx)))s")
		transcriptionLogger.info("Cloud request total elapsed \(String(format: "%.2f", Date().timeIntervalSince(startAll)))s")
		return text
	}

	func beginRealtimeSession(model: String, options: TranscriptionOptions) async throws {
		guard CloudTranscriptionModel.isCloud(model) else {
			throw TranscriptionClientError.unsupportedModel(model)
		}

		let apiKey = APIKeyClient.liveValue.getOpenAIKey()
		transcriptionLogger.notice("Starting realtime transcription session model=\(model)")
		try await realtimeCoordinator.activate(model: model, language: options.language, apiKey: apiKey)
	}

	func waitForRealtimeSessionReady() async throws {
		try await realtimeCoordinator.waitUntilReady()
	}

	func appendRealtimeAudio(samples: [Float]) async {
		await realtimeCoordinator.append(samples: samples)
	}

	func finishRealtimeSession() async throws -> String {
		let start = Date()
		let text = try await realtimeCoordinator.finish()
		transcriptionLogger.info(
			"Realtime transcription commit-to-text took \(String(format: "%.2f", Date().timeIntervalSince(start)))s"
		)
		return text
	}

	func cancelRealtimeSession() async {
		await realtimeCoordinator.cancel()
	}
}

enum TranscriptionClientError: LocalizedError {
	case unsupportedModel(String)

	var errorDescription: String? {
		switch self {
		case let .unsupportedModel(name):
			"Unsupported transcription model: \(name)"
		}
	}
}
