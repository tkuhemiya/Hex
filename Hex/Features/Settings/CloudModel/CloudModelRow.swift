import ComposableArchitecture
import Inject
import SwiftUI

struct CloudModelRow: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<CloudModelFeature>
	let model: CloudModelInfo

	private var isSelected: Bool {
		store.hexSettings.selectedModel == model.internalName
	}

	var body: some View {
		Button(action: { store.send(.selectModel(model.internalName)) }) {
			HStack(alignment: .center, spacing: 12) {
				Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
					.foregroundStyle(isSelected ? .blue : .secondary)

				VStack(alignment: .leading, spacing: 6) {
					HStack(spacing: 6) {
						Text(model.displayName)
							.font(.headline)
						Text("CLOUD")
							.font(.caption2)
							.fontWeight(.semibold)
							.foregroundStyle(.white)
							.padding(.horizontal, 6)
							.padding(.vertical, 2)
							.background(Color.accentColor)
							.clipShape(RoundedRectangle(cornerRadius: 4))
					}
					HStack(spacing: 16) {
						HStack(spacing: 6) {
							StarRatingView(model.accuracyStars)
							Text("Accuracy").font(.caption2).foregroundStyle(.secondary)
						}
						HStack(spacing: 6) {
							StarRatingView(model.speedStars)
							Text("Speed").font(.caption2).foregroundStyle(.secondary)
						}
					}
				}

				Spacer(minLength: 12)

				Text(model.size)
					.foregroundStyle(.secondary)
					.font(.subheadline)
			}
			.padding(10)
			.background(
				RoundedRectangle(cornerRadius: 10)
					.fill(isSelected ? Color.blue.opacity(0.08) : Color(NSColor.controlBackgroundColor))
			)
			.overlay(
				RoundedRectangle(cornerRadius: 10)
					.stroke(isSelected ? Color.blue.opacity(0.35) : Color.gray.opacity(0.18))
			)
			.contentShape(.rect)
		}
		.buttonStyle(.plain)
		.enableInjection()
	}
}
