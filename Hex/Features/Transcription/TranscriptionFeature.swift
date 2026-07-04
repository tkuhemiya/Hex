//
//  TranscriptionFeature.swift
//  Hex
//
//  Created by Kit Langton on 1/24/25.
//

import ComposableArchitecture
import CoreGraphics
import Foundation
import HexCore
import Inject
import SwiftUI

private let transcriptionFeatureLogger = HexLog.transcription

@Reducer
struct TranscriptionFeature {
  @ObservableState
  struct State {
    var isRecording: Bool = false
    var isTranscribing: Bool = false
    var isPrewarming: Bool = false
    var error: String?
    var recordingStartTime: Date?
    var meter: Meter = .init(averagePower: 0, peakPower: 0)
    @Shared(.hexSettings) var hexSettings: HexSettings
    @Shared(.isRemappingScratchpadFocused) var isRemappingScratchpadFocused: Bool = false
    @Shared(.transcriptionReadinessState) var transcriptionReadinessState: TranscriptionReadinessState
  }

  enum Action {
    case task
    case audioLevelUpdated(Meter)

    // Hotkey actions
    case startRecording
    case stopRecording

    // Cancel/discard flow
    case cancel   // Explicit cancellation with sound
    case discard  // Silent discard (too short/accidental)

    // Transcription result flow
    case transcriptionResult(String, TimeInterval)
    case transcriptionError(Error)
    case recordingSessionStartFailed(Error)

    // Model availability
    case modelMissing
  }

  enum CancelID {
    case metering
    case recordingStart
    case recordingCleanup
    case transcription
  }

  @Dependency(\.transcription) var transcription
  @Dependency(\.recording) var recording
  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.soundEffects) var soundEffect
  @Dependency(\.sleepManagement) var sleepManagement
  @Dependency(\.date.now) var now

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      // MARK: - Lifecycle / Setup

      case .task:
        // Starts two concurrent effects:
        // 1) Observing audio meter
        // 2) Monitoring hot key events
        // 3) Priming the recorder for instant startup
        return .merge(
          startMeteringEffect(),
          startHotKeyMonitoringEffect(),
          warmUpRecorderEffect()
        )

      // MARK: - Metering

      case let .audioLevelUpdated(meter):
        state.meter = meter
        return .none

      // MARK: - Recording Flow

      case .startRecording:
        return handleStartRecording(&state)

      case .stopRecording:
        return handleStopRecording(&state)

      // MARK: - Transcription Results

      case let .transcriptionResult(result, duration):
        return handleTranscriptionResult(&state, result: result, duration: duration)

      case let .transcriptionError(error):
        return handleTranscriptionError(&state, error: error)

      case let .recordingSessionStartFailed(error):
        return handleRecordingSessionStartFailed(&state, error: error)

      case .modelMissing:
        return .none

      // MARK: - Cancel/Discard Flow

      case .cancel:
        // Only cancel if we're in the middle of recording, transcribing, or post-processing
        guard state.isRecording || state.isTranscribing else {
          return .none
        }
        return handleCancel(&state)

      case .discard:
        // Silent discard for quick/accidental recordings
        guard state.isRecording else {
          return .none
        }
        return handleDiscard(&state)
      }
    }
  }
}

// MARK: - Effects: Metering & HotKey

private extension TranscriptionFeature {
  /// Effect to begin observing the audio meter.
  func startMeteringEffect() -> Effect<Action> {
    .run { send in
      for await meter in await recording.observeAudioLevel() {
        await send(.audioLevelUpdated(meter))
      }
    }
    .cancellable(id: CancelID.metering, cancelInFlight: true)
  }

  /// Effect to start monitoring hotkey events through the `keyEventMonitor`.
  func startHotKeyMonitoringEffect() -> Effect<Action> {
    .run { send in
      var hotKeyProcessor: HotKeyProcessor = .init(hotkey: HotKey(key: nil, modifiers: [.option]))
      @Shared(.isSettingHotKey) var isSettingHotKey: Bool
      @Shared(.hexSettings) var hexSettings: HexSettings

      // Handle incoming input events (keyboard and mouse)
      let token = keyEventMonitor.handleInputEvent { inputEvent in
        // Skip if the user is currently setting a hotkey
        if isSettingHotKey {
          return false
        }

        // Always keep hotKeyProcessor in sync with current user hotkey preference
        hotKeyProcessor.hotkey = hexSettings.hotkey

        switch inputEvent {
        case .keyboard(let keyEvent):
          // If Escape is pressed with no modifiers while idle, treat that as cancel.
          if keyEvent.key == .escape, keyEvent.modifiers.isEmpty,
             hotKeyProcessor.state == .idle
          {
            Task { await send(.cancel) }
            return false
          }

          switch hotKeyProcessor.process(keyEvent: keyEvent) {
          case .startRecording:
            Task { await send(.startRecording) }
            return keyEvent.key != nil

          case .stopRecording:
            Task { await send(.stopRecording) }
            return keyEvent.key != nil

          case .cancel:
            Task { await send(.cancel) }
            return true

          case .none:
            if let pressedKey = keyEvent.key,
               pressedKey == hotKeyProcessor.hotkey.key,
               keyEvent.modifiers == hotKeyProcessor.hotkey.modifiers
            {
              return true
            }
            return false
          }

        case .mouseClick:
          _ = hotKeyProcessor.processMouseClick()
          return false
        }
      }

      defer { token.cancel() }

      await withTaskCancellationHandler {
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(60))
        }
      } onCancel: {
        token.cancel()
      }
    }
  }

  func warmUpRecorderEffect() -> Effect<Action> {
    .run { _ in
      await recording.warmUpRecorder()
    }
  }
}

// MARK: - Recording Handlers

private extension TranscriptionFeature {
  func handleStartRecording(_ state: inout State) -> Effect<Action> {
    if state.isTranscribing {
      return .concatenate(
        .send(.cancel),
        .send(.startRecording)
      )
    }

    guard state.transcriptionReadinessState.isAPIKeyConfigured else {
      return .merge(
        .send(.modelMissing),
        .run { _ in soundEffect.play(.cancel) }
      )
    }
    state.isRecording = true
    let startTime = now
    state.recordingStartTime = startTime
    transcriptionFeatureLogger.notice("Recording started at \(startTime.ISO8601Format())")

    let model = state.hexSettings.selectedModel
    let language = state.hexSettings.outputLanguage
    let useRealtimeTranscription = state.hexSettings.transcriptionDeliveryMode == .realtime

    // Prevent system sleep during recording
    return .merge(
      .cancel(id: CancelID.recordingCleanup),
      .run { [sleepManagement, preventSleep = state.hexSettings.preventSystemSleep] send in
        // Play sound immediately for instant feedback
        soundEffect.play(.startRecording)

        if preventSleep {
          await sleepManagement.preventSleep(reason: "Hex Voice Recording")
        }
        guard !Task.isCancelled else {
          if preventSleep {
            await sleepManagement.allowSleep()
          }
          return
        }

        if useRealtimeTranscription {
          do {
            let options = TranscriptionOptions(language: language)
            try await transcription.beginRealtimeSession(model, options)
            await recording.setRealtimeSampleHandler { samples in
              Task {
                await transcription.appendRealtimeAudio(samples)
              }
            }
          } catch {
            transcriptionFeatureLogger.error(
              "Failed to start realtime transcription session: \(error.localizedDescription)"
            )
            await transcription.cancelRealtimeSession()
            if preventSleep {
              await sleepManagement.allowSleep()
            }
            await send(.recordingSessionStartFailed(error))
            return
          }

          await withTaskGroup(of: Void.self) { group in
            group.addTask {
              await recording.startRecording()
            }
            group.addTask {
              do {
                try await transcription.waitForRealtimeSessionReady()
              } catch {
                guard !Task.isCancelled else { return }
                transcriptionFeatureLogger.error(
                  "Realtime transcription session failed during recording: \(error.localizedDescription)"
                )
                await recording.clearRealtimeSampleHandler()
                await transcription.cancelRealtimeSession()
                _ = await recording.stopRecording()
                if preventSleep {
                  await sleepManagement.allowSleep()
                }
                await send(.recordingSessionStartFailed(error))
              }
            }
          }
        } else {
          await recording.startRecording()
        }
      }
      .cancellable(id: CancelID.recordingStart, cancelInFlight: true)
    )
  }

  func handleStopRecording(_ state: inout State) -> Effect<Action> {
    state.isRecording = false
    
    let stopTime = now
    let startTime = state.recordingStartTime
    let duration = startTime.map { stopTime.timeIntervalSince($0) } ?? 0

    let decision = RecordingDecisionEngine.decide(elapsed: duration)

    let startStamp = startTime?.ISO8601Format() ?? "nil"
    let stopStamp = stopTime.ISO8601Format()
    transcriptionFeatureLogger.notice(
      "Recording stopped duration=\(String(format: "%.3f", duration))s start=\(startStamp) stop=\(stopStamp) decision=\(String(describing: decision))"
    )

    guard decision == .proceedToTranscription else {
      transcriptionFeatureLogger.notice("Discarding short recording per decision \(String(describing: decision))")
      return handleDiscard(&state)
    }

    // Otherwise, proceed to transcription
    state.isTranscribing = true
    state.error = nil
    let model = state.hexSettings.selectedModel
    let language = state.hexSettings.outputLanguage
    let useRealtimeTranscription = state.hexSettings.transcriptionDeliveryMode == .realtime

    state.isPrewarming = true

    return .merge(
      .cancel(id: CancelID.recordingStart),
      .run { [sleepManagement] send in
        await sleepManagement.allowSleep()

        do {
          if useRealtimeTranscription {
            await recording.clearRealtimeSampleHandler()
            _ = await recording.stopRecording()
            guard !Task.isCancelled else { return }
            soundEffect.play(.stopRecording)

            let result = try await transcription.finishRealtimeSession()
            transcriptionFeatureLogger.notice("Realtime transcribed text length \(result.count)")
            await send(.transcriptionResult(result, duration))
          } else {
            let capturedAudio = await recording.stopRecording()
            guard !Task.isCancelled, !capturedAudio.isEmpty else { return }
            soundEffect.play(.stopRecording)

            let options = TranscriptionOptions(language: language)
            let result = try await transcription.transcribe(
              capturedAudio.wavData,
              model,
              options
            ) { _ in }

            transcriptionFeatureLogger.notice(
              "Transcribed \(capturedAudio.wavData.count) bytes to text length \(result.count)"
            )
            await send(.transcriptionResult(result, duration))
          }
        } catch {
          await transcription.cancelRealtimeSession()
          await recording.clearRealtimeSampleHandler()
          if Self.shouldTreatRealtimeStopErrorAsEmptyTranscript(error) {
            transcriptionFeatureLogger.notice(
              "Realtime pipeline ended without audio; treating as empty transcript"
            )
            await send(.transcriptionResult("", duration))
          } else {
            transcriptionFeatureLogger.error("Transcription failed: \(error.localizedDescription)")
            await send(.transcriptionError(error))
          }
        }
      }
      .cancellable(id: CancelID.transcription)
    )
  }
}

// MARK: - Transcription Handlers

private extension TranscriptionFeature {
  func handleTranscriptionResult(
    _ state: inout State,
    result: String,
    duration: TimeInterval
  ) -> Effect<Action> {
    state.isTranscribing = false
    state.isPrewarming = false

    if ForceQuitCommandDetector.matches(result) {
      transcriptionFeatureLogger.fault("Force quit voice command recognized; terminating Hex.")
      return .run { _ in
        await MainActor.run {
          NSApp.terminate(nil)
        }
      }
    }

    guard !result.isEmpty else {
      return .none
    }

    transcriptionFeatureLogger.info("Raw transcription: '\(result, privacy: .private)'")
    let remappings = state.hexSettings.wordRemappings
    let removalsEnabled = state.hexSettings.wordRemovalsEnabled
    let removals = state.hexSettings.wordRemovals
    let modifiedResult: String
    if state.isRemappingScratchpadFocused {
      modifiedResult = result
      transcriptionFeatureLogger.info("Scratchpad focused; skipping word modifications")
    } else {
      var output = result
      if removalsEnabled {
        let removedResult = WordRemovalApplier.apply(output, removals: removals)
        if removedResult != output {
          let enabledRemovalCount = removals.filter(\.isEnabled).count
          transcriptionFeatureLogger.info("Applied \(enabledRemovalCount) word removal(s)")
        }
        output = removedResult
      }
      let remappedResult = WordRemappingApplier.apply(output, remappings: remappings)
      if remappedResult != output {
        transcriptionFeatureLogger.info("Applied \(remappings.count) word remapping(s)")
      }
      modifiedResult = remappedResult
    }

    guard !modifiedResult.isEmpty else {
      return .none
    }

    return .run { _ in
      await pasteboard.paste(modifiedResult)
      soundEffect.play(.pasteTranscript)
    }
    .cancellable(id: CancelID.transcription)
  }

  func handleTranscriptionError(
    _ state: inout State,
    error: Error
  ) -> Effect<Action> {
    state.isTranscribing = false
    state.isPrewarming = false
    state.error = error.localizedDescription
    return .none
  }

  func handleRecordingSessionStartFailed(
    _ state: inout State,
    error: Error
  ) -> Effect<Action> {
    state.isRecording = false
    state.recordingStartTime = nil
    state.isTranscribing = false
    state.isPrewarming = false
    state.error = error.localizedDescription
    return .merge(
      .cancel(id: CancelID.recordingStart),
      .run { _ in
        soundEffect.play(.cancel)
      }
    )
  }

  static func shouldTreatRealtimeStopErrorAsEmptyTranscript(_ error: Error) -> Bool {
    guard let error = error as? RealtimeTranscriptionError else { return false }
    switch error {
    case .notConnected, .emptyAudioBuffer:
      return true
    case .missingAPIKey, .sessionNotReady, .commitTimedOut, .serverError, .connectionClosed, .invalidEvent:
      return false
    }
  }
}

// MARK: - Cancel/Discard Handlers

private extension TranscriptionFeature {
  func handleCancel(_ state: inout State) -> Effect<Action> {
    let wasRecording = state.isRecording
    state.isTranscribing = false
    state.isRecording = false
    state.isPrewarming = false

    return .merge(
      .cancel(id: CancelID.transcription),
      .cancel(id: CancelID.recordingStart),
      .run { [sleepManagement] _ in
        // Allow system to sleep again
        await sleepManagement.allowSleep()
        guard wasRecording else {
          soundEffect.play(.cancel)
          return
        }
        await recording.clearRealtimeSampleHandler()
        await transcription.cancelRealtimeSession()
        _ = await recording.stopRecording()
        guard !Task.isCancelled else { return }
        soundEffect.play(.cancel)
      }
      .cancellable(id: CancelID.recordingCleanup, cancelInFlight: true)
    )
  }

  func handleDiscard(_ state: inout State) -> Effect<Action> {
    state.isRecording = false
    state.isPrewarming = false

    // Silently discard - no sound effect
    return .merge(
      .cancel(id: CancelID.recordingStart),
      .run { [sleepManagement] _ in
        // Allow system to sleep again
        await sleepManagement.allowSleep()
        await recording.clearRealtimeSampleHandler()
        await transcription.cancelRealtimeSession()
        _ = await recording.stopRecording()
        guard !Task.isCancelled else { return }
      }
      .cancellable(id: CancelID.recordingCleanup, cancelInFlight: true)
    )
  }
}

// MARK: - View

struct TranscriptionView: View {
  @Bindable var store: StoreOf<TranscriptionFeature>
  @ObserveInjection var inject

  var status: TranscriptionIndicatorView.Status {
    if store.isTranscribing {
      return .transcribing
    } else if store.isRecording {
      return .recording
    } else if store.isPrewarming {
      return .prewarming
    } else {
      return .hidden
    }
  }

  var body: some View {
    TranscriptionIndicatorView(
      status: status,
      meter: store.meter
    )
    .task {
      await store.send(.task).finish()
    }
    .enableInjection()
  }
}

// MARK: - Force Quit Command

private enum ForceQuitCommandDetector {
  static func matches(_ text: String) -> Bool {
    let normalized = normalize(text)
    return normalized == "force quit hex now" || normalized == "force quit hex"
  }

  private static func normalize(_ text: String) -> String {
    text
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }
}
