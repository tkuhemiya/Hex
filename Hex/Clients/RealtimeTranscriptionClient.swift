//
//  RealtimeTranscriptionClient.swift
//  Hex
//
//  Push-to-talk Realtime transcription: stream PCM while recording, commit once on stop.
//  Set `RealtimeTranscriptionSettings.isEnabled = true` to try this path.
//

import Foundation
import HexCore

private let logger = HexLog.transcription

/// Flip to route recordings through the Realtime API instead of `/v1/audio/transcriptions`.
enum RealtimeTranscriptionSettings {
  static let isEnabled = false
}

enum RealtimeTranscriptionError: LocalizedError {
  case missingAPIKey
  case notConnected
  case sessionNotReady
  case emptyAudioBuffer
  case commitTimedOut
  case serverError(String)
  case connectionClosed
  case invalidEvent(String)

  var errorDescription: String? {
    switch self {
    case .missingAPIKey:
      "OpenAI API key is not configured"
    case .notConnected:
      "Realtime transcription session is not connected"
    case .sessionNotReady:
      "Realtime transcription session is not ready to accept audio"
    case .emptyAudioBuffer:
      "No audio was streamed before commit"
    case .commitTimedOut:
      "Timed out waiting for the final transcript"
    case let .serverError(message):
      "OpenAI Realtime error: \(message)"
    case .connectionClosed:
      "Realtime transcription connection closed unexpectedly"
    case let .invalidEvent(message):
      "Unexpected Realtime event: \(message)"
    }
  }
}

/// Coordinates a single in-flight Realtime session (Hex records one utterance at a time).
actor RealtimeTranscriptionCoordinator {
  private var session: RealtimeTranscriptionSession?

  func start(model: String, language: String?, apiKey: String?) async throws {
    if let session {
      await session.cancel()
      self.session = nil
    }

    let nextSession = try await RealtimeTranscriptionSession.connect(
      model: model,
      language: language,
      apiKey: apiKey
    )
    session = nextSession
  }

  func append(samples: [Float]) async throws {
    guard let session else { throw RealtimeTranscriptionError.notConnected }
    try await session.append(samples: samples)
  }

  func finish() async throws -> String {
    guard let session else { throw RealtimeTranscriptionError.notConnected }
    defer { self.session = nil }
    return try await session.commit()
  }

  func cancel() async {
    if let session {
      await session.cancel()
    }
    session = nil
  }
}

// MARK: - Session

private actor RealtimeTranscriptionSession {
  private let webSocket: URLSessionWebSocketTask
  private var receiveTask: Task<Void, Never>?
  private var isSessionReady = false
  private var hasAppendedAudio = false
  private var pendingCommit: CheckedContinuation<String, Error>?
  private var serverError: String?

  static func connect(
    model: String,
    language: String?,
    apiKey: String?
  ) async throws -> RealtimeTranscriptionSession {
    guard let apiKey, !apiKey.isEmpty else {
      throw RealtimeTranscriptionError.missingAPIKey
    }

    var request = URLRequest(url: Self.endpoint)
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

    let webSocket = URLSession.shared.webSocketTask(with: request)
    webSocket.resume()

    let session = RealtimeTranscriptionSession(webSocket: webSocket)
    try await session.bootstrap(model: model, language: language)

    logger.notice("Realtime transcription session ready model=\(model)")
    return session
  }

  private func bootstrap(model: String, language: String?) async throws {
    receiveTask = Task { await receiveLoop() }
    try await sendSessionConfiguration(model: model, language: language)
    try await waitUntilReady()
  }

  private static let endpoint = URL(
    string: "wss://api.openai.com/v1/realtime?intent=transcription"
  )!

  private init(webSocket: URLSessionWebSocketTask) {
    self.webSocket = webSocket
  }

  func append(samples: [Float]) async throws {
    guard isSessionReady else { throw RealtimeTranscriptionError.sessionNotReady }
    guard !samples.isEmpty else { return }

    let pcmData = PCMSampleConverter.float32ToPCM16Resampled(samples: samples)
    guard !pcmData.isEmpty else { return }

    let payload: [String: Any] = [
      "type": "input_audio_buffer.append",
      "audio": pcmData.base64EncodedString(),
    ]
    try await sendJSON(payload)
    hasAppendedAudio = true
  }

  func commit() async throws -> String {
    guard isSessionReady else { throw RealtimeTranscriptionError.sessionNotReady }
    guard hasAppendedAudio else { throw RealtimeTranscriptionError.emptyAudioBuffer }

    logger.notice("Committing realtime audio buffer for transcription")

    try await sendJSON(["type": "input_audio_buffer.commit"])

    return try await withCheckedThrowingContinuation { continuation in
      pendingCommit = continuation

      Task {
        try? await Task.sleep(for: .seconds(60))
        guard let pendingCommit = self.pendingCommit else { return }
        self.pendingCommit = nil
        pendingCommit.resume(throwing: RealtimeTranscriptionError.commitTimedOut)
      }
    }
  }

  func cancel() async {
    pendingCommit?.resume(throwing: CancellationError())
    pendingCommit = nil
    try? await sendJSON(["type": "input_audio_buffer.clear"])
    webSocket.cancel(with: .goingAway, reason: nil)
    receiveTask?.cancel()
  }

  // MARK: - Configuration

  private func sendSessionConfiguration(model: String, language: String?) async throws {
    var transcription: [String: Any] = ["model": model]
    if let language, !language.isEmpty {
      transcription["language"] = language
    }

    // Manual push-to-talk: omit `turn_detection` so only our commit ends the turn.
    let payload: [String: Any] = [
      "type": "transcription_session.update",
      "session": [
        "input_audio_format": "pcm16",
        "input_audio_transcription": transcription,
      ],
    ]

    try await sendJSON(payload)
  }

  private func waitUntilReady() async throws {
    let deadline = Date().addingTimeInterval(10)
    while !isSessionReady {
      if let serverError {
        throw RealtimeTranscriptionError.serverError(serverError)
      }
      if Date() > deadline {
        throw RealtimeTranscriptionError.sessionNotReady
      }
      try await Task.sleep(for: .milliseconds(25))
    }
  }

  // MARK: - WebSocket

  private func sendJSON(_ object: [String: Any]) async throws {
    let data = try JSONSerialization.data(withJSONObject: object)
    guard let text = String(data: data, encoding: .utf8) else {
      throw RealtimeTranscriptionError.invalidEvent("Failed to encode JSON payload")
    }
    try await webSocket.send(.string(text))
  }

  private func receiveLoop() async {
    while !Task.isCancelled {
      do {
        let message = try await webSocket.receive()
        switch message {
        case let .string(text):
          handleEvent(text)
        case let .data(data):
          handleEvent(String(data: data, encoding: .utf8) ?? "")
        @unknown default:
          break
        }
      } catch {
        if pendingCommit != nil {
          pendingCommit?.resume(throwing: RealtimeTranscriptionError.connectionClosed)
          pendingCommit = nil
        }
        logger.error("Realtime websocket receive failed: \(error.localizedDescription)")
        break
      }
    }
  }

  private func handleEvent(_ text: String) {
    guard
      let data = text.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let type = json["type"] as? String
    else {
      return
    }

    switch type {
    case "transcription_session.created",
         "transcription_session.updated",
         "session.created",
         "session.updated":
      isSessionReady = true

    case "conversation.item.input_audio_transcription.completed":
      let transcript = (json["transcript"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      logger.notice("Realtime transcription completed length=\(transcript.count)")
      pendingCommit?.resume(returning: transcript)
      pendingCommit = nil

    case "conversation.item.input_audio_transcription.delta":
      // Ignore partial text — Hex pastes once on completed.
      break

    case "error":
      let message = Self.describeError(json)
      logger.error("Realtime transcription server error: \(message, privacy: .public)")
      serverError = message
      pendingCommit?.resume(throwing: RealtimeTranscriptionError.serverError(message))
      pendingCommit = nil

    case "input_audio_buffer.committed",
         "input_audio_buffer.cleared",
         "conversation.item.created",
         "conversation.item.done":
      break

    default:
      logger.debug("Realtime event type=\(type, privacy: .public)")
    }
  }

  private static func describeError(_ json: [String: Any]) -> String {
    if let error = json["error"] as? [String: Any] {
      let code = error["code"] as? String ?? "unknown"
      let message = error["message"] as? String ?? "Unknown error"
      return "\(code): \(message)"
    }
    return "Unknown error"
  }
}
