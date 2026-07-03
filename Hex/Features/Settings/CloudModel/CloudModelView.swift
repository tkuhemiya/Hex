import ComposableArchitecture
import Inject
import SwiftUI

public struct CloudModelView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<CloudModelFeature>
	var shouldFlash: Bool = false

	public init(store: StoreOf<CloudModelFeature>, shouldFlash: Bool = false) {
		self.store = store
		self.shouldFlash = shouldFlash
	}

	public var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			if !store.transcriptionReadinessState.isAPIKeyConfigured {
				apiKeyBanner
			}

			ForEach(store.models) { model in
				CloudModelRow(store: store, model: model)
			}
		}
		.frame(maxWidth: 500)
		.task {
			if store.models.isEmpty {
				store.send(.loadModels)
			}
		}
		.enableInjection()
	}

	private var apiKeyBanner: some View {
		HStack(alignment: .top, spacing: 10) {
			Image(systemName: "key.fill")
				.font(.system(size: 16, weight: .semibold))
				.foregroundStyle(Color.accentColor)

			VStack(alignment: .leading, spacing: 6) {
				Text("Add an OpenAI API key to start transcribing")
					.font(.system(size: 12, weight: .semibold))
				Text("Recordings are sent to OpenAI for transcription. Add your key above.")
					.font(.system(size: 11))
					.foregroundStyle(.secondary)
			}
		}
		.padding(12)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(RoundedRectangle(cornerRadius: 10).fill(.thinMaterial))
		.overlay(
			RoundedRectangle(cornerRadius: 10)
				.stroke(Color.accentColor.opacity(shouldFlash ? 0.8 : 0.25), lineWidth: shouldFlash ? 3 : 1)
				.animation(.easeInOut(duration: 0.5).repeatCount(3, autoreverses: true), value: shouldFlash)
		)
	}
}
