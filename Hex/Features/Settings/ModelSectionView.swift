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
					"sk-…",
					text: Binding(
						get: { store.openAIAPIKey },
						set: { store.send(.setOpenAIAPIKey($0)) }
					)
				)
				.textFieldStyle(.roundedBorder)
				Text("Required for the cloud model. Create a key at platform.openai.com.")
					.settingsCaption()
			}
			.padding(.vertical, 4)

			ModelDownloadView(
				store: store.scope(state: \.modelDownload, action: \.modelDownload),
				shouldFlash: shouldFlash
			)
		} header: {
			Text("Transcription Model")
		}
		.enableInjection()
	}
}
