import Foundation
import Testing
@testable import HexCore

@Test func emptySamplesAreIgnored() {
	var buffer = RealtimeSampleBuffer()
	buffer.enqueue([])
	#expect(buffer.pendingChunkCount == 0)
	#expect(buffer.hasAudio == false)
}

@Test func enqueueTracksAudioAndPreservesOrder() {
	var buffer = RealtimeSampleBuffer()
	buffer.enqueue([0.1, 0.2])
	buffer.enqueue([0.3])

	#expect(buffer.hasAudio == true)
	#expect(buffer.pendingChunkCount == 2)

	let chunks = buffer.takePending()
	#expect(chunks == [[0.1, 0.2], [0.3]])
	#expect(buffer.pendingChunkCount == 0)
	#expect(buffer.hasAudio == true)
}

@Test func takePendingCanBeCalledMultipleTimes() {
	var buffer = RealtimeSampleBuffer()
	buffer.enqueue([1])
	#expect(buffer.takePending() == [[1]])
	#expect(buffer.takePending().isEmpty)
}
