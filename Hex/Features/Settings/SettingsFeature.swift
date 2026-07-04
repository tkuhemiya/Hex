import AVFoundation
import AppKit
import ComposableArchitecture
import CoreAudio
import Dependencies
import HexCore
import IdentifiedCollections
import Sauce
import ServiceManagement
import SwiftUI

private let settingsLogger = HexLog.settings
private typealias SettingsAudioPropertyListenerBlock = @convention(block) (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void

extension SharedReaderKey
  where Self == InMemoryKey<Bool>.Default
{
  static var isSettingHotKey: Self {
    Self[.inMemory("isSettingHotKey"), default: false]
  }

  static var isRemappingScratchpadFocused: Self {
    Self[.inMemory("isRemappingScratchpadFocused"), default: false]
  }
}

// MARK: - Settings Feature

@Reducer
struct SettingsFeature {
  @ObservableState
  struct State {
    @Shared(.hexSettings) var hexSettings: HexSettings
    @Shared(.isSettingHotKey) var isSettingHotKey: Bool = false
    @Shared(.isRemappingScratchpadFocused) var isRemappingScratchpadFocused: Bool = false
    @Shared(.hotkeyPermissionState) var hotkeyPermissionState: HotkeyPermissionState
    @Shared(.transcriptionReadinessState) var transcriptionReadinessState: TranscriptionReadinessState

    var languages: IdentifiedArrayOf<Language> = []
    var currentModifiers: Modifiers = .init(modifiers: [])
    var remappingScratchpadText: String = ""
    
    // Available microphones
    var availableInputDevices: [AudioInputDevice] = []
    var defaultInputDeviceName: String?

    // Model Management
    var cloudModel = CloudModelFeature.State()
    var shouldFlashModelSection = false
    /// Draft text while the user types a new key. Never pre-filled from the keychain.
    var openAIAPIKeyDraft: String = ""
    var hasOpenAIAPIKey: Bool = false

  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)

    // Existing
    case task
    case startSettingHotKey
    case keyEvent(KeyEvent)
    case toggleOpenOnLogin(Bool)
    case toggleShowDockIcon(Bool)
    case togglePreventSystemSleep(Bool)
    case setRecordingAudioBehavior(RecordingAudioBehavior)
    case toggleSuperFastMode(Bool)
    case setUseClipboardPaste(Bool)
    case setOutputLanguage(String?)
    case setSelectedMicrophoneID(String?)
    case setSoundEffectsEnabled(Bool)
    case setSoundEffectsVolume(Double)

    // Permission delegation (forwarded to AppFeature)
    case requestMicrophone
    case requestAccessibility
    case requestInputMonitoring

    // Microphone selection
    case loadAvailableInputDevices
    case availableInputDevicesLoaded([AudioInputDevice], String?)

    // Model Management
    case cloudModel(CloudModelFeature.Action)
    case setOpenAIAPIKeyDraft(String)
    case saveOpenAIAPIKey
    case openAIAPIKeySaved
    case clearOpenAIAPIKey
    
    // Modifier configuration
    case setModifierSide(Modifier.Kind, Modifier.Side)

    // Word remappings
    case setWordRemovalsEnabled(Bool)
    case addWordRemoval
    case updateWordRemoval(WordRemoval)
    case removeWordRemoval(UUID)
    case addWordRemapping
    case updateWordRemapping(WordRemapping)
    case removeWordRemapping(UUID)
    case setRemappingScratchpadFocused(Bool)
  }

  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.transcription) var transcription
  @Dependency(\.recording) var recording
  @Dependency(\.soundEffects) var soundEffects
  @Dependency(\.apiKey) var apiKey

  private func beginHotKeyCapture(state: inout State) {
    state.$isSettingHotKey.withLock { $0 = true }
    state.currentModifiers = .init(modifiers: [])
  }

  private func endHotKeyCapture(state: inout State) {
    state.$isSettingHotKey.withLock { $0 = false }
    state.currentModifiers = .init(modifiers: [])
  }

  private func handleHotKeyCapture(_ keyEvent: KeyEvent, state: inout State) -> Effect<Action> {
    if keyEvent.key == .escape {
      endHotKeyCapture(state: &state)
      return .none
    }

    let updatedModifiers = keyEvent.modifiers.union(state.currentModifiers)
    state.currentModifiers = updatedModifiers

    if let key = keyEvent.key {
      state.$hexSettings.withLock {
        $0.hotkey.key = key
        $0.hotkey.modifiers = updatedModifiers.erasingSides()
      }
      endHotKeyCapture(state: &state)
      return .none
    }

    if keyEvent.modifiers.isEmpty {
      state.$hexSettings.withLock {
        $0.hotkey.key = nil
        $0.hotkey.modifiers = updatedModifiers.erasingSides()
      }
      endHotKeyCapture(state: &state)
    }

    return .none
  }

  var body: some ReducerOf<Self> {
    BindingReducer()

    Scope(state: \.cloudModel, action: \.cloudModel) {
      CloudModelFeature()
    }

    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .task:
        let hasKey = apiKey.getOpenAIKey().map { !$0.isEmpty } ?? false
        state.hasOpenAIAPIKey = hasKey
        state.$transcriptionReadinessState.withLock {
          $0.isAPIKeyConfigured = hasKey
          $0.lastError = hasKey ? nil : "OpenAI API key is not configured"
        }

        if let url = Bundle.main.url(forResource: "languages", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let languages = try? JSONDecoder().decode([Language].self, from: data)
        {
          state.languages = IdentifiedArray(uniqueElements: languages)
        } else {
          settingsLogger.error("Failed to load languages JSON from bundle")
        }

        // Listen for key events and load microphones (existing + new)
        return .run { send in
          func audioPropertyAddress(
            _ selector: AudioObjectPropertySelector,
            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
            element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
          ) -> AudioObjectPropertyAddress {
            AudioObjectPropertyAddress(
              mSelector: selector,
              mScope: scope,
              mElement: element
            )
          }

          await send(.cloudModel(.loadModels))
          await send(.loadAvailableInputDevices)

          // Listen for device connection/disconnection notifications
          // Using a simpler debounced approach with a single task
          var deviceUpdateTask: Task<Void, Never>?
          var audioHardwareObservers: [(AudioObjectPropertySelector, SettingsAudioPropertyListenerBlock)] = []

          // Helper function to debounce device updates
          func debounceDeviceUpdate() {
            deviceUpdateTask?.cancel()
            deviceUpdateTask = Task {
              try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
              if !Task.isCancelled {
                await send(.loadAvailableInputDevices)
              }
            }
          }

          func installAudioHardwareObserver(_ selector: AudioObjectPropertySelector) {
            let listener: SettingsAudioPropertyListenerBlock = { _, _ in
              debounceDeviceUpdate()
            }
            var address = audioPropertyAddress(selector)
            let status = AudioObjectAddPropertyListenerBlock(
              AudioObjectID(kAudioObjectSystemObject),
              &address,
              DispatchQueue.main,
              listener
            )

            if status == noErr {
              audioHardwareObservers.append((selector, listener))
            } else {
              settingsLogger.error("Failed to observe audio hardware selector \(selector): \(status)")
            }
          }

          let deviceConnectionObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name(rawValue: "AVCaptureDeviceWasConnected"),
            object: nil,
            queue: .main
          ) { _ in
            debounceDeviceUpdate()
          }
          
          let deviceDisconnectionObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name(rawValue: "AVCaptureDeviceWasDisconnected"),
            object: nil,
            queue: .main
          ) { _ in
            debounceDeviceUpdate()
          }

          let appDidBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
          ) { _ in
            debounceDeviceUpdate()
          }

          let wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
          ) { _ in
            debounceDeviceUpdate()
          }

          installAudioHardwareObserver(kAudioHardwarePropertyDefaultInputDevice)
          installAudioHardwareObserver(kAudioHardwarePropertyDevices)

          // Be sure to clean up resources when the task is finished
          defer {
            deviceUpdateTask?.cancel()
            NotificationCenter.default.removeObserver(deviceConnectionObserver)
            NotificationCenter.default.removeObserver(deviceDisconnectionObserver)
            NotificationCenter.default.removeObserver(appDidBecomeActiveObserver)
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)

            for (selector, listener) in audioHardwareObservers {
              var address = audioPropertyAddress(selector)
              let status = AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.main,
                listener
              )
              if status != noErr {
                settingsLogger.error("Failed to remove audio hardware observer for selector \(selector): \(status)")
              }
            }
          }

          for try await keyEvent in await keyEventMonitor.listenForKeyPress() {
            await send(.keyEvent(keyEvent))
          }
          
        }

      case .startSettingHotKey:
        beginHotKeyCapture(state: &state)
        return .none

      case let .keyEvent(keyEvent):
        guard state.isSettingHotKey else { return .none }
        return handleHotKeyCapture(keyEvent, state: &state)

      case .addWordRemoval:
        state.$hexSettings.withLock {
          $0.wordRemovals.append(.init(pattern: ""))
        }
        return .none

      case let .updateWordRemoval(removal):
        state.$hexSettings.withLock {
          guard let index = $0.wordRemovals.firstIndex(where: { $0.id == removal.id }) else { return }
          $0.wordRemovals[index] = removal
        }
        return .none

      case let .removeWordRemoval(id):
        state.$hexSettings.withLock {
          $0.wordRemovals.removeAll { $0.id == id }
        }
        return .none

      case .addWordRemapping:
        state.$hexSettings.withLock {
          $0.wordRemappings.append(.init(match: "", replacement: ""))
        }
        return .none

      case let .updateWordRemapping(remapping):
        state.$hexSettings.withLock {
          guard let index = $0.wordRemappings.firstIndex(where: { $0.id == remapping.id }) else { return }
          $0.wordRemappings[index] = remapping
        }
        return .none

      case let .removeWordRemapping(id):
        state.$hexSettings.withLock {
          $0.wordRemappings.removeAll { $0.id == id }
        }
        return .none

      case let .setRemappingScratchpadFocused(isFocused):
        state.$isRemappingScratchpadFocused.withLock { $0 = isFocused }
        return .none

      case let .toggleOpenOnLogin(enabled):
        state.$hexSettings.withLock { $0.openOnLogin = enabled }
        return .run { _ in
          if enabled {
            try? SMAppService.mainApp.register()
          } else {
            try? SMAppService.mainApp.unregister()
          }
        }

      case let .toggleShowDockIcon(enabled):
        state.$hexSettings.withLock { $0.showDockIcon = enabled }
        return .run { _ in
          await MainActor.run {
            NotificationCenter.default.post(name: .updateAppMode, object: nil)
          }
        }

      case let .togglePreventSystemSleep(enabled):
        state.$hexSettings.withLock { $0.preventSystemSleep = enabled }
        return .none

      case let .setUseClipboardPaste(enabled):
        state.$hexSettings.withLock { $0.useClipboardPaste = enabled }
        return .none

      case let .setRecordingAudioBehavior(behavior):
        state.$hexSettings.withLock { $0.recordingAudioBehavior = behavior }
        return .none

      case let .toggleSuperFastMode(enabled):
        state.$hexSettings.withLock { $0.superFastModeEnabled = enabled }
        return .run { _ in
          await recording.warmUpRecorder()
        }

      case let .setOutputLanguage(language):
        state.$hexSettings.withLock { $0.outputLanguage = language }
        return .none

      case let .setSelectedMicrophoneID(deviceID):
        state.$hexSettings.withLock { $0.selectedMicrophoneID = deviceID }
        return .run { _ in
          await recording.warmUpRecorder()
        }

      case let .setSoundEffectsEnabled(enabled):
        state.$hexSettings.withLock { $0.soundEffectsEnabled = enabled }
        return .run { _ in
          await soundEffects.setEnabled(enabled)
        }

      case let .setSoundEffectsVolume(volume):
        state.$hexSettings.withLock { $0.soundEffectsVolume = volume }
        return .none

      // Permission requests
      case .requestMicrophone:
        settingsLogger.info("User requested microphone permission from settings")
        return .none

      case .requestAccessibility:
        settingsLogger.info("User requested accessibility permission from settings")
        return .none

      case .requestInputMonitoring:
        settingsLogger.info("User requested input monitoring permission from settings")
        return .none

      // Model Management
      case let .setOpenAIAPIKeyDraft(draft):
        state.openAIAPIKeyDraft = draft
        return .none

      case .saveOpenAIAPIKey:
        let draft = state.openAIAPIKeyDraft
        guard !draft.isEmpty else { return .none }
        return .run { [apiKey] send in
          do {
            try apiKey.setOpenAIKey(draft)
            await send(.openAIAPIKeySaved)
          } catch {
            settingsLogger.error("Failed to save OpenAI API key: \(error.localizedDescription)")
          }
        }

      case .openAIAPIKeySaved:
        state.hasOpenAIAPIKey = true
        state.openAIAPIKeyDraft = ""
        state.$transcriptionReadinessState.withLock {
          $0.isAPIKeyConfigured = true
          $0.lastError = nil
        }
        return .none

      case .clearOpenAIAPIKey:
        state.hasOpenAIAPIKey = false
        state.openAIAPIKeyDraft = ""
        state.$transcriptionReadinessState.withLock {
          $0.isAPIKeyConfigured = false
          $0.lastError = "OpenAI API key is not configured"
        }
        return .run { [apiKey] _ in
          try? apiKey.setOpenAIKey(nil)
        }

      case .cloudModel:
        return .none
      
      // Microphone device selection
      case .loadAvailableInputDevices:
        return .run { send in
          let devices = await recording.getAvailableInputDevices()
          let defaultName = await recording.getDefaultInputDeviceName()
          await send(.availableInputDevicesLoaded(devices, defaultName))
        }
        
      case let .availableInputDevicesLoaded(devices, defaultName):
        if let selectedMicrophoneID = state.hexSettings.selectedMicrophoneID,
           let device = devices.first(where: { $0.legacyID == selectedMicrophoneID }) {
          state.availableInputDevices = devices
          state.defaultInputDeviceName = defaultName
          return .send(.setSelectedMicrophoneID(device.id))
        }
        state.availableInputDevices = devices
        state.defaultInputDeviceName = defaultName
        return .none
        
      case let .setModifierSide(kind, side):
        guard state.hexSettings.hotkey.key == nil else { return .none }
        state.$hexSettings.withLock {
          $0.hotkey.modifiers = $0.hotkey.modifiers.setting(kind: kind, to: side)
        }
        return .none

      case let .setWordRemovalsEnabled(enabled):
        state.$hexSettings.withLock { $0.wordRemovalsEnabled = enabled }
        return .none

      }
    }
  }
}
