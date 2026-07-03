import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct ModelSectionView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>
	let shouldFlash: Bool

	var body: some View {
		Section {
			VStack(alignment: .leading, spacing: 8) {
				Text("OpenAI API Key")
					.font(.headline)
				SecureField(
					store.hasOpenAIAPIKey ? "Enter a new key to replace the saved one" : "sk-…",
					text: Binding(
						get: { store.openAIAPIKeyDraft },
						set: { store.send(.setOpenAIAPIKeyDraft($0)) }
					)
				)
				.textFieldStyle(.roundedBorder)
				HStack(spacing: 12) {
					if store.hasOpenAIAPIKey {
						Image(systemName: "checkmark.circle.fill")
							.foregroundStyle(.green)
						Text("API key saved")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
					Spacer()
					Button("Add API key") {
						store.send(.saveOpenAIAPIKey)
					}
					.buttonStyle(.borderless)
					.font(.caption)
					.disabled(store.openAIAPIKeyDraft.isEmpty)
					if store.hasOpenAIAPIKey {
						Button("Remove") {
							store.send(.clearOpenAIAPIKey)
						}
						.buttonStyle(.borderless)
						.font(.caption)
					}
				}
				Text("Required for the cloud model. Create a key at platform.openai.com.")
					.settingsCaption()
			}
			.padding(.vertical, 4)

			CloudModelView(
				store: store.scope(state: \.cloudModel, action: \.cloudModel),
				shouldFlash: shouldFlash
			)
		} header: {
			Text("Transcription Model")
		}
		.enableInjection()
	}
}
