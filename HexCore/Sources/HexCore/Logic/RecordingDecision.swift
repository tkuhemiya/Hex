import Foundation

/// Determines whether a recording should be kept or discarded based on duration.
public struct RecordingDecisionEngine {
    /// Minimum session length before transcription proceeds.
    ///
    /// Prevents empty transcriptions from instant toggle-off (press → press again).
    public static let minimumRecordingDuration: TimeInterval = HexCoreConstants.minimumRecordingDuration

    public enum Decision: Equatable {
        case discardShortRecording
        case proceedToTranscription
    }

    /// - Parameter elapsed: Total recording duration in seconds
    public static func decide(elapsed: TimeInterval) -> Decision {
        elapsed >= minimumRecordingDuration ? .proceedToTranscription : .discardShortRecording
    }
}
