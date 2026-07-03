import ComposableArchitecture

struct TranscriptionReadinessState: Equatable {
	var isAPIKeyConfigured: Bool = false
	var lastError: String?
}

extension SharedReaderKey
	where Self == InMemoryKey<TranscriptionReadinessState>.Default
{
	static var transcriptionReadinessState: Self {
		Self[
			.inMemory("transcriptionReadinessState"),
			default: .init()
		]
	}
}
