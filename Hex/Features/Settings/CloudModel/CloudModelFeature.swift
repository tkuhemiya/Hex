import ComposableArchitecture
import Foundation
import HexCore
import IdentifiedCollections

public struct CloudModelInfo: Equatable, Identifiable, Codable {
	public let displayName: String
	public let internalName: String
	public let provider: String?
	public let size: String
	public let accuracyStars: Int
	public let speedStars: Int
	public var id: String { internalName }
}

private enum CloudModelLoader {
	private static let bundledModels: [CloudModelInfo] = {
		guard let url = Bundle.main.url(forResource: "models", withExtension: "json") ??
			Bundle.main.url(forResource: "models", withExtension: "json", subdirectory: "Data")
		else {
			assertionFailure("models.json not found in bundle")
			return []
		}
		do {
			return try JSONDecoder().decode([CloudModelInfo].self, from: Data(contentsOf: url))
		} catch {
			assertionFailure("Failed to decode models.json - \(error)")
			return []
		}
	}()

	static func load() -> [CloudModelInfo] {
		bundledModels
	}
}

@Reducer
public struct CloudModelFeature {
	@ObservableState
	public struct State: Equatable {
		@Shared(.hexSettings) var hexSettings: HexSettings
		@Shared(.transcriptionReadinessState) var transcriptionReadinessState: TranscriptionReadinessState

		public var models: IdentifiedArrayOf<CloudModelInfo> = []
	}

	public enum Action {
		case loadModels
		case selectModel(String)
	}

	public init() {}

	public var body: some ReducerOf<Self> {
		Reduce { state, action in
			switch action {
			case .loadModels:
				let models = CloudModelLoader.load()
				state.models = IdentifiedArrayOf(uniqueElements: models)
				if !CloudTranscriptionModel.isCloud(state.hexSettings.selectedModel),
				   let defaultModel = models.first
				{
					state.$hexSettings.withLock {
						$0.selectedModel = defaultModel.internalName
					}
				}
				return .none

			case let .selectModel(model):
				guard CloudTranscriptionModel.isCloud(model) else { return .none }
				state.$hexSettings.withLock { $0.selectedModel = model }
				return .none
			}
		}
	}
}
