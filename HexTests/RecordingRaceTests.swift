import AppKit
import ComposableArchitecture
import Foundation
import HexCore
import Testing

@testable import Hex

@Suite(.serialized)
@MainActor
struct RecordingRaceTests {
  @Test
  func newRecordingCancelsPendingDiscardCleanup() async throws {
    let now = Date(timeIntervalSince1970: 1_234)
    let activeApp = NSWorkspace.shared.frontmostApplication
    let capturedAudio = CapturedAudio(wavData: Data("test".utf8), duration: 0.5)
    let probe = RecordingProbe(capturedAudio: capturedAudio)

    let store = TestStore(initialState: Self.makeState()) {
      TranscriptionFeature()
    } withDependencies: {
      $0.date.now = now
      $0.recording.startRecording = {
        await probe.recordStart()
      }
      $0.recording.stopRecording = {
        await probe.beginStop()
      }
      $0.sleepManagement.preventSleep = { _ in }
      $0.sleepManagement.allowSleep = {}
      $0.soundEffects.play = { _ in }
    }

    await store.send(.startRecording) {
      $0.isRecording = true
      $0.recordingStartTime = now
    }
    await store.send(.discard) {
      $0.isRecording = false
      $0.isPrewarming = false
    }

    await probe.waitForPendingStop()

    await store.send(.startRecording) {
      $0.isRecording = true
      $0.recordingStartTime = now
    }

    await probe.resumePendingStop()
    await store.finish()

    let counts = await probe.counts()
    #expect(counts.startCalls == 2)
    #expect(counts.stopCalls == 1)
  }

  @Test
  func stopGuardIgnoresOnlyStaleSessions() {
    let currentSessionID = UUID()

    #expect(
      RecordingClientLive.shouldIgnoreStopRequest(
        snapshotSessionID: currentSessionID,
        currentSessionID: currentSessionID
      ) == false
    )
    #expect(
      RecordingClientLive.shouldIgnoreStopRequest(
        snapshotSessionID: nil,
        currentSessionID: currentSessionID
      ) == false
    )
    #expect(
      RecordingClientLive.shouldIgnoreStopRequest(
        snapshotSessionID: currentSessionID,
        currentSessionID: UUID()
      )
    )
  }

  @Test
  func shortRecordingReleasesSleepAssertion() async throws {
    let now = Date(timeIntervalSince1970: 1_234)
    let capturedAudio = CapturedAudio(wavData: Data("test".utf8), duration: 0.5)
    let probe = SleepProbe()
    let store = TestStore(initialState: Self.makeState()) {
      TranscriptionFeature()
    } withDependencies: {
      $0.date.now = now
      $0.recording.startRecording = {}
      $0.recording.stopRecording = { capturedAudio }
      $0.sleepManagement.preventSleep = { _ in
        await probe.recordPreventSleep()
      }
      $0.sleepManagement.allowSleep = {
        await probe.recordAllowSleep()
      }
      $0.soundEffects.play = { _ in }
    }

    await store.send(.startRecording) {
      $0.isRecording = true
      $0.recordingStartTime = now
    }
    await store.send(.stopRecording) {
      $0.isRecording = false
    }
    await store.finish()

    let counts = await probe.counts()
    #expect(counts.preventSleepCalls == 1)
    #expect(counts.allowSleepCalls == 1)
  }

  @Test
  func discardCancelsPendingRecordingStart() async {
    let now = Date(timeIntervalSince1970: 1_234)
    let capturedAudio = CapturedAudio(wavData: Data("test".utf8), duration: 0.5)
    let sleepProbe = PendingSleepProbe()
    let recordingProbe = RecordingProbe(capturedAudio: capturedAudio)
    let store = TestStore(initialState: Self.makeState()) {
      TranscriptionFeature()
    } withDependencies: {
      $0.date.now = now
      $0.recording.startRecording = {
        await recordingProbe.recordStart()
      }
      $0.recording.stopRecording = {
        await recordingProbe.beginImmediateStop()
      }
      $0.sleepManagement.preventSleep = { _ in
        await sleepProbe.preventSleep()
      }
      $0.sleepManagement.allowSleep = {}
      $0.soundEffects.play = { _ in }
    }

    await store.send(.startRecording) {
      $0.isRecording = true
      $0.recordingStartTime = now
    }
    await sleepProbe.waitUntilPending()
    await store.send(.discard) {
      $0.isRecording = false
      $0.isPrewarming = false
    }
    await sleepProbe.resume()
    await store.finish()

    let counts = await recordingProbe.counts()
    #expect(counts.startCalls == 0)
    #expect(counts.stopCalls == 1)
  }

  @Test
  func emptyTranscriptionDoesNothing() async throws {
    let store = TestStore(initialState: Self.makeState()) {
      TranscriptionFeature()
    }

    await store.send(.transcriptionResult("", 1.25))
    await store.finish()
  }

  private static func makeState() -> TranscriptionFeature.State {
    TranscriptionFeature.State(
      hexSettings: Shared(.init()),
      isRemappingScratchpadFocused: Shared(false),
      transcriptionReadinessState: Shared(.init(isAPIKeyConfigured: true))
    )
  }
}

private actor RecordingProbe {
  private let capturedAudio: CapturedAudio
  private var startCalls = 0
  private var stopCalls = 0
  private var stopContinuation: CheckedContinuation<CapturedAudio, Never>?

  init(capturedAudio: CapturedAudio) {
    self.capturedAudio = capturedAudio
  }

  func recordStart() {
    startCalls += 1
  }

  func beginStop() async -> CapturedAudio {
    stopCalls += 1
    return await withCheckedContinuation { continuation in
      stopContinuation = continuation
    }
  }

  func beginImmediateStop() -> CapturedAudio {
    stopCalls += 1
    return capturedAudio
  }

  func waitForPendingStop() async {
    while stopContinuation == nil {
      await Task.yield()
    }
  }

  func resumePendingStop() {
    stopContinuation?.resume(returning: capturedAudio)
    stopContinuation = nil
  }

  func counts() -> (startCalls: Int, stopCalls: Int) {
    (startCalls, stopCalls)
  }
}

private actor SleepProbe {
  private var preventSleepCalls = 0
  private var allowSleepCalls = 0

  func recordPreventSleep() {
    preventSleepCalls += 1
  }

  func recordAllowSleep() {
    allowSleepCalls += 1
  }

  func counts() -> (preventSleepCalls: Int, allowSleepCalls: Int) {
    (preventSleepCalls, allowSleepCalls)
  }
}

private actor PendingSleepProbe {
  private var continuation: CheckedContinuation<Void, Never>?

  func preventSleep() async {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func waitUntilPending() async {
    while continuation == nil {
      await Task.yield()
    }
  }

  func resume() {
    continuation?.resume()
    continuation = nil
  }
}
