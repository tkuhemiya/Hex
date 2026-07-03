import Inject
import SwiftUI

struct AboutView: View {
	@ObserveInjection var inject

	var body: some View {
		Form {
			Section {
				HStack {
					Label("Version", systemImage: "info.circle")
					Spacer()
					Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown")
						.foregroundStyle(.secondary)
				}
			}
		}
		.formStyle(.grouped)
		.enableInjection()
	}
}
