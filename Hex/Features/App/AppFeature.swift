//
//  AppFeature.swift
//  Hex
//
//  Created by Kit Langton on 1/26/25.
//

import AppKit
import ComposableArchitecture
import Dependencies
import HexCore
import SwiftUI

@Reducer
struct AppFeature {
  enum ActiveTab: Equatable {
    case settings
    case remappings
    case about
  }

	@ObservableState
	struct State {
		var transcription: TranscriptionFeature.State = .init()
		var settings: SettingsFeature.State = .init()
		var activeTab: ActiveTab = .settings
		@Shared(.hexSettings) var hexSettings: HexSettings
		@Shared(.transcriptionReadinessState) var transcriptionReadinessState: TranscriptionReadinessState

    // Permission state
    var microphonePermission: PermissionStatus = .notDetermined
    var accessibilityPermission: PermissionStatus = .notDetermined
    var inputMonitoringPermission: PermissionStatus = .notDetermined
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case transcription(TranscriptionFeature.Action)
    case settings(SettingsFeature.Action)
    case setActiveTab(ActiveTab)
    case task

    // Permission actions
    case checkPermissions
    case permissionsUpdated(mic: PermissionStatus, acc: PermissionStatus, input: PermissionStatus)
    case appActivated
    case modelStatusEvaluated(Bool)
  }

  @Dependency(\.permissions) var permissions
  @Dependency(\.apiKey) var apiKey

  var body: some ReducerOf<Self> {
    BindingReducer()

    Scope(state: \.transcription, action: \.transcription) {
      TranscriptionFeature()
    }

    Scope(state: \.settings, action: \.settings) {
      SettingsFeature()
    }

    Reduce { state, action in
      switch action {
      case .binding:
        return .none
        
      case .task:
        return .merge(
          ensureSelectedModelReadiness(),
          startPermissionMonitoring()
        )
        
      case .transcription(.modelMissing):
        HexLog.app.notice("API key missing - activating app and switching to settings")
        state.activeTab = .settings
        state.settings.shouldFlashModelSection = true
        return .run { send in
          await MainActor.run {
            HexLog.app.notice("Activating app for missing API key")
            NSApplication.shared.activate(ignoringOtherApps: true)
          }
          try? await Task.sleep(for: .seconds(2))
          await send(.settings(.set(\.shouldFlashModelSection, false)))
        }

      case .transcription:
        return .none

      case .settings(.requestMicrophone):
        return .run { send in
          _ = await permissions.requestMicrophone()
          await send(.checkPermissions)
        }

      case .settings(.requestAccessibility):
        return .run { send in
          await permissions.requestAccessibility()
          for _ in 0..<10 {
            try? await Task.sleep(for: .seconds(1))
            await send(.checkPermissions)
          }
        }

      case .settings(.requestInputMonitoring):
        return .run { send in
          _ = await permissions.requestInputMonitoring()
          for _ in 0..<10 {
            try? await Task.sleep(for: .seconds(1))
            await send(.checkPermissions)
          }
        }

      case .settings:
        return .none

		case let .setActiveTab(tab):
			state.activeTab = tab
			return .none

      case .checkPermissions:
        return .run { send in
          async let mic = permissions.microphoneStatus()
          async let acc = permissions.accessibilityStatus()
          async let input = permissions.inputMonitoringStatus()
          await send(.permissionsUpdated(mic: mic, acc: acc, input: input))
        }

      case let .permissionsUpdated(mic, acc, input):
        state.microphonePermission = mic
        state.accessibilityPermission = acc
        state.inputMonitoringPermission = input
        return .none

      case .appActivated:
        return .send(.checkPermissions)

      case .modelStatusEvaluated:
        return .none
      }
    }
  }

  private func ensureSelectedModelReadiness() -> Effect<Action> {
    .run { send in
      @Shared(.hexSettings) var hexSettings: HexSettings
      @Shared(.transcriptionReadinessState) var transcriptionReadinessState: TranscriptionReadinessState
      let selectedModel = hexSettings.selectedModel
      guard !selectedModel.isEmpty else {
        await send(.modelStatusEvaluated(false))
        return
      }
      let hasKey = apiKey.getOpenAIKey().map { !$0.isEmpty } ?? false
      $transcriptionReadinessState.withLock { state in
        state.isAPIKeyConfigured = hasKey
        if hasKey {
          state.lastError = nil
        } else {
          state.lastError = "OpenAI API key is not configured"
        }
      }
      await send(.modelStatusEvaluated(hasKey))
    }
  }

  private func startPermissionMonitoring() -> Effect<Action> {
    .run { send in
      await send(.checkPermissions)

      for await activation in permissions.observeAppActivation() {
        if case .didBecomeActive = activation {
          await send(.appActivated)
        }
      }

    }
  }

}

struct AppView: View {
  @Bindable var store: StoreOf<AppFeature>
  @State private var columnVisibility = NavigationSplitViewVisibility.automatic

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      List(selection: $store.activeTab) {
        Button {
          store.send(.setActiveTab(.settings))
        } label: {
          Label("Settings", systemImage: "gearshape")
        }
        .buttonStyle(.plain)
        .tag(AppFeature.ActiveTab.settings)

        Button {
          store.send(.setActiveTab(.remappings))
        } label: {
          Label("Transforms", systemImage: "text.badge.plus")
        }
        .buttonStyle(.plain)
        .tag(AppFeature.ActiveTab.remappings)

        Button {
          store.send(.setActiveTab(.about))
        } label: {
          Label("About", systemImage: "info.circle")
        }
        .buttonStyle(.plain)
        .tag(AppFeature.ActiveTab.about)
      }
    } detail: {
      switch store.state.activeTab {
      case .settings:
        SettingsView(
          store: store.scope(state: \.settings, action: \.settings),
          microphonePermission: store.microphonePermission,
          accessibilityPermission: store.accessibilityPermission,
          inputMonitoringPermission: store.inputMonitoringPermission
        )
        .navigationTitle("Settings")
      case .remappings:
        WordRemappingsView(store: store.scope(state: \.settings, action: \.settings))
          .navigationTitle("Transforms")
      case .about:
        AboutView()
          .navigationTitle("About")
      }
    }
    .enableInjection()
  }
}
