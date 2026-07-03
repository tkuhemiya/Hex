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
	var transcribe: @Sendable (URL, String, TranscriptionOptions, @escaping (Progress) -> Void) async throws -> String
	var isReady: @Sendable () async -> Bool = { false }
}

extension TranscriptionClient: DependencyKey {
	static var liveValue: Self {
		let live = TranscriptionClientLive()
		return Self(
			transcribe: { try await live.transcribe(url: $0, model: $1, options: $2, progressCallback: $3) },
			isReady: { await live.isReady() }
		)
	}

	static let testValue = Self(
		transcribe: { _, _, _, _ in "" },
		isReady: { true }
	)
}

extension DependencyValues {
	var transcription: TranscriptionClient {
		get { self[TranscriptionClient.self] }
		set { self[TranscriptionClient.self] = newValue }
	}
}

struct TranscriptionClientLive: Sendable {
	func isReady() async -> Bool {
		guard let key = APIKeyClient.liveValue.getOpenAIKey(), !key.isEmpty else {
			return false
		}
		return true
	}

	func transcribe(
		url: URL,
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
		transcriptionLogger.notice("Transcribing with cloud model=\(model) file=\(url.lastPathComponent)")

		let apiKey = APIKeyClient.liveValue.getOpenAIKey()
		let startTx = Date()
		let text = try await OpenAITranscriptionClient().transcribe(
			url: url,
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
