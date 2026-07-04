import Foundation

/// Central repository for timing thresholds and magic numbers used throughout HexCore.
public enum HexCoreConstants {

    // MARK: - Hotkey Timing Thresholds

    /// Minimum recording duration before transcription proceeds on toggle-off.
    ///
    /// **Value:** 0.2 seconds
    public static let minimumRecordingDuration: TimeInterval = 0.2

    // MARK: - Default Settings

    /// Base volume for sound effects (before user multiplier applied).
    ///
    /// **Value:** 0.2 (20%)
    public static let baseSoundEffectsVolume: Double = 0.2
}
