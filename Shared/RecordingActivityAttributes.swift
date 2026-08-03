import ActivityKit
import Foundation

/// Compiled into both the app (which starts/updates the Live Activity) and the
/// MinuteWidgets extension (which renders it). ActivityKit matches the two
/// sides by this type, so they must share one definition.
struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        /// Now minus already-recorded time — `Text(_, style: .timer)` counts
        /// up from it, so the lock screen ticks without any app updates.
        var startedAt: Date
        var isPaused: Bool
        /// Total recorded time, shown as a static value while paused.
        var elapsed: TimeInterval
    }

    /// Meeting title as it was when recording started.
    var title: String
}
