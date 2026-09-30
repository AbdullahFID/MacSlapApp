import Foundation

public enum SensitivityLevel: Int, CaseIterable, Sendable {
    case veryLow = 0, low, medium, high, veryHigh

    public var displayName: String {
        switch self {
        case .veryLow: return "Requires Significant Force"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .veryHigh: return "Extremely Sensitive"
        }
    }

    /// Thresholds derived from on-device captures: hard typing peaks at
    /// ~0.12 g with low coincident jerk, so even the most sensitive level
    /// (amp 0.15 g AND jerk 14 g/s) rejects it with margin, while real slaps
    /// (≥0.5 g and tens–hundreds g/s of jerk) clear every level.
    public var detectorConfig: DetectorConfig {
        switch self {
        case .veryHigh:   // "Extremely Sensitive" — soft slaps count, typing doesn't
            return DetectorConfig(ampThreshold: 0.15, jerkThreshold: 14, hardAmpThreshold: 0.45)
        case .high:
            return DetectorConfig(ampThreshold: 0.25, jerkThreshold: 20, hardAmpThreshold: 0.60)
        case .medium:
            return DetectorConfig(ampThreshold: 0.40, jerkThreshold: 30, hardAmpThreshold: 0.90)
        case .low:
            return DetectorConfig(ampThreshold: 0.70, jerkThreshold: 50, hardAmpThreshold: 1.50)
        case .veryLow:    // "Requires Significant Force" — only firm/hard slaps
            return DetectorConfig(ampThreshold: 1.10, jerkThreshold: 90, hardAmpThreshold: 2.20)
        }
    }
}
