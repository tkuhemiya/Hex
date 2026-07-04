//
//  RealtimeTranscriptionClient.swift
//  Hex
//
//  Push-to-talk Realtime transcription: stream PCM while recording, commit once on stop.
//

import Foundation
import HexCore

private let logger = HexLog.transcription

enum RealtimeTranscriptionError: LocalizedError, Equatable {
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
///
/// Mic capture can begin before the WebSocket handshake completes. Samples are buffered locally
/// until the session is ready, then flushed in order.
actor RealtimeTranscriptionCoordinator {
  private struct ActivePipeline {
    let generation: UInt64
    var session: RealtimeTranscriptionSession?
    var connectTask: Task<Void, Never>?
    var pendingSamples = RealtimeSampleBuffer()
    var hasAudio = false
    var connectError: Error?
  }

  private var pipeline: ActivePipeline?
  private var generation: UInt64 = 0

  /// Begins connecting in the background and returns immediately so capture can start in parallel.
  func activate(model: String, language: String?, apiKey: String?) async throws {
    guard let apiKey, !apiKey.isEmpty else {
      throw RealtimeTranscriptionError.missingAPIKey
    }

    await deactivate()

    generation += 1
    let activeGeneration = generation
    logger.notice("Activating realtime transcription pipeline model=\(model)")

    let connectTask = Task { [activeGeneration] in
      do {
        let session = try await RealtimeTranscriptionSession.connect(
          model: model,
          language: language,
          apiKey: apiKey
        )
        await self.handleConnectSuccess(generation: activeGeneration, session: session)
      } catch is CancellationError {
        logger.debug("Realtime connect cancelled generation=\(activeGeneration)")
      } catch {
        await self.handleConnectFailure(generation: activeGeneration, error: error)
      }
    }

    pipeline = ActivePipeline(
      generation: activeGeneration,
      session: nil,
      connectTask: connectTask,
      pendingSamples: RealtimeSampleBuffer(),
      hasAudio: false,
      connectError: nil
    )
  }

  func append(samples: [Float]) async {
    guard !samples.isEmpty else { return }
    guard var active = pipeline else { return }

    active.hasAudio = true

    if let session = active.session {
      try? await session.append(samples: samples)
    } else {
      active.pendingSamples.enqueue(samples)
    }

    pipeline = active
  }

  func waitUntilReady() async throws {
    try await awaitPipelineReady()
  }

  func finish() async throws -> String {
    guard pipeline != nil else {
      throw RealtimeTranscriptionError.notConnected
    }

    try await awaitPipelineReady()

    guard var active = pipeline else {
      throw RealtimeTranscriptionError.notConnected
    }

    if let connectError = active.connectError {
      pipeline = nil
      throw connectError
    }

    guard active.hasAudio else {
      pipeline = nil
      throw RealtimeTranscriptionError.emptyAudioBuffer
    }

    guard let session = active.session else {
      pipeline = nil
      throw RealtimeTranscriptionError.notConnected
    }

    pipeline = nil
    return try await session.commit()
  }

  func cancel() async {
    await deactivate()
  }

  // MARK: - Pipeline lifecycle

  private func awaitPipelineReady() async throws {
    guard var active = pipeline else {
      throw RealtimeTranscriptionError.notConnected
    }

    if active.session != nil {
      return
    }

    if let connectError = active.connectError {
      throw connectError
    }

    if let connectTask = active.connectTask {
      await connectTask.value
      active = pipeline ?? active
    }

    if let connectError = active.connectError {
      throw connectError
    }

    guard active.session != nil else {
      throw RealtimeTranscriptionError.sessionNotReady
    }
  }

  private func handleConnectSuccess(
    generation: UInt64,
    session: RealtimeTranscriptionSession
  ) async {
    guard var active = pipeline, active.generation == generation else {
      await session.cancel()
      return
    }

    active.session = session
    active.connectTask = nil

    let pendingChunks = active.pendingSamples.takePending()
    pipeline = active

    for chunk in pendingChunks {
      try? await session.append(samples: chunk)
    }

    logger.notice(
      "Realtime transcription session ready flushedBufferedChunks=\(pendingChunks.count)"
    )
  }

  private func handleConnectFailure(generation: UInt64, error: Error) async {
    guard var active = pipeline, active.generation == generation else { return }

    active.connectError = error
    active.connectTask = nil
    pipeline = active

    logger.error(
      "Realtime transcription connect failed: \(error.localizedDescription, privacy: .public)"
    )
  }

  private func deactivate() async {
    guard let active = pipeline else { return }

    pipeline = nil
    active.connectTask?.cancel()

    if let session = active.session {
      await session.cancel()
    }
  }
}

// MARK: - Session

private actor RealtimeTranscriptionSession {
  private let webSocket: URLSessionWebSocketTask
  private let transcriptionModel: String
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

    var request = URLRequest(url: RealtimeTranscriptionConfiguration.webSocketURL)
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

    let webSocket = URLSession.shared.webSocketTask(with: request)
    webSocket.resume()

    let session = RealtimeTranscriptionSession(webSocket: webSocket, transcriptionModel: model)
    do {
      try await session.bootstrap(language: language)
      return session
    } catch {
      await session.cancel()
      throw error
    }
  }

  private func bootstrap(language: String?) async throws {
    try Task.checkCancellation()
    receiveTask = Task { await receiveLoop() }
    try await sendSessionConfiguration(language: language)
    try await waitUntilReady()
  }

  private init(webSocket: URLSessionWebSocketTask, transcriptionModel: String) {
    self.webSocket = webSocket
    self.transcriptionModel = transcriptionModel
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

  private func sendSessionConfiguration(language: String?) async throws {
    let payload = RealtimeTranscriptionConfiguration.sessionUpdatePayload(
      transcriptionModel: transcriptionModel,
      language: language
    )
    try await sendJSON(payload)
  }

  private func waitUntilReady() async throws {
    let deadline = Date().addingTimeInterval(10)
    while !isSessionReady {
      try Task.checkCancellation()
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
        if !Task.isCancelled {
          logger.error("Realtime websocket receive failed: \(error.localizedDescription)")
        }
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
    case "session.created", "session.updated":
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
