//
//  OpenAITranscriptionClient.swift
//  Hex
//

import Foundation
import HexCore

private let logger = HexLog.transcription

enum OpenAITranscriptionError: LocalizedError {
  case missingAPIKey
  case invalidResponse
  case apiError(statusCode: Int, message: String)

  var errorDescription: String? {
    switch self {
    case .missingAPIKey:
      "OpenAI API key is not configured"
    case .invalidResponse:
      "Invalid response from OpenAI"
    case let .apiError(statusCode, message):
      "OpenAI API error (\(statusCode)): \(message)"
    }
  }
}

struct OpenAITranscriptionClient: Sendable {
  private static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

  func transcribe(
    url: URL,
    model: String,
    language: String?,
    apiKey: String?
  ) async throws -> String {
    guard let apiKey, !apiKey.isEmpty else {
      throw OpenAITranscriptionError.missingAPIKey
    }

    let audioData = try Data(contentsOf: url)
    let boundary = "HexBoundary-\(UUID().uuidString)"
    var body = Data()
    appendField(to: &body, boundary: boundary, name: "model", value: model)
    if let language, !language.isEmpty {
      appendField(to: &body, boundary: boundary, name: "language", value: language)
    }
    appendFile(
      to: &body,
      boundary: boundary,
      name: "file",
      filename: url.lastPathComponent,
      mimeType: mimeType(for: url),
      data: audioData
    )
    body.append("--\(boundary)--\r\n".data(using: .utf8)!)

    var request = URLRequest(url: Self.endpoint)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.httpBody = body

    logger.notice("Sending cloud transcription request model=\(model) file=\(url.lastPathComponent)")
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw OpenAITranscriptionError.invalidResponse
    }
    guard (200 ... 299).contains(http.statusCode) else {
      let message = String(data: data, encoding: .utf8) ?? "Unknown error"
      logger.error("OpenAI transcription failed status=\(http.statusCode)")
      throw OpenAITranscriptionError.apiError(statusCode: http.statusCode, message: message)
    }

    struct TranscriptionResponse: Decodable {
      let text: String
    }
    let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
    return decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func mimeType(for url: URL) -> String {
    switch url.pathExtension.lowercased() {
    case "mp3": "audio/mpeg"
    case "mp4", "m4a": "audio/mp4"
    case "webm": "audio/webm"
    default: "audio/wav"
    }
  }

  private func appendField(to body: inout Data, boundary: String, name: String, value: String) {
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
    body.append("\(value)\r\n".data(using: .utf8)!)
  }

  private func appendFile(
    to body: inout Data,
    boundary: String,
    name: String,
    filename: String,
    mimeType: String,
    data: Data
  ) {
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append(
      "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n"
        .data(using: .utf8)!
    )
    body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
    body.append(data)
    body.append("\r\n".data(using: .utf8)!)
  }
}
