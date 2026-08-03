import ActivityKit
import Foundation
import OSLog

/// Mirrors one recording session's phase onto a lock-screen / Dynamic Island
/// Live Activity, so a locked iPhone still shows the recording is running.
@MainActor
final class RecordingLiveActivityController {
    private static let logger = Logger(subsystem: "com.minuteapp.Minute", category: "LiveActivity")

    private var activity: Activity<RecordingActivityAttributes>?
    /// ActivityKit updates are async — chain them so a quick pause → resume →
    /// stop can't land out of order and leave a stale card on the lock screen.
    private var chain: Task<Void, Never>?

    func start(title: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = RecordingActivityAttributes.ContentState(startedAt: .now, isPaused: false, elapsed: 0)
        do {
            activity = try Activity.request(
                attributes: RecordingActivityAttributes(title: title),
                content: ActivityContent(state: state, staleDate: nil)
            )
        } catch {
            // The activity is a convenience mirror — never fail recording over it.
            Self.logger.error("Starting Live Activity failed: \(error.localizedDescription)")
        }
    }

    func update(isPaused: Bool, elapsed: TimeInterval) {
        guard let activity else { return }
        let state = RecordingActivityAttributes.ContentState(
            startedAt: Date(timeIntervalSinceNow: -elapsed),
            isPaused: isPaused,
            elapsed: elapsed
        )
        enqueue { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        enqueue { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// Ends activities a crash or force-quit left behind. Called at app launch,
    /// when no recording can be running.
    static func endOrphans() {
        Task {
            for orphan in Activity<RecordingActivityAttributes>.activities {
                await orphan.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    private func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        chain = Task { [previous = chain] in
            await previous?.value
            await operation()
        }
    }
}
