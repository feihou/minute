import ActivityKit
import SwiftUI
import WidgetKit

/// Lock-screen card and Dynamic Island presentation for an in-progress
/// recording. The timer runs off `startedAt`, so it ticks with no updates
/// from the app.
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            LockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    StatusBadge(isPaused: context.state.isPaused, isStale: context.isStale)
                        .font(.callout)
                        .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TimerText(state: context.state, isStale: context.isStale)
                        .font(.title3.weight(.medium))
                        .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.attributes.title)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } compactLeading: {
                StatusIcon(isPaused: context.state.isPaused)
            } compactTrailing: {
                TimerText(state: context.state, isStale: context.isStale)
                    .font(.caption2)
                    .foregroundStyle(context.state.isPaused ? Color.orange : Color.red)
                    .frame(maxWidth: 52)
            } minimal: {
                StatusIcon(isPaused: context.state.isPaused)
            }
            .keylineTint(.red)
        }
    }
}

/// Matches the in-app recording screen: dark studio backdrop, red/orange
/// status badge, large rounded timer.
private struct LockScreenView: View {
    let context: ActivityViewContext<RecordingActivityAttributes>

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(
                    LinearGradient(
                        colors: [.red, .red.opacity(0.75)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                )
                .opacity(context.state.isPaused ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(context.attributes.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                StatusBadge(isPaused: context.state.isPaused, isStale: context.isStale)
                    .font(.caption)
            }
            Spacer(minLength: 8)
            TimerText(state: context.state, isStale: context.isStale)
                .font(.system(size: 30, weight: .medium, design: .rounded))
        }
        .padding(16)
        .foregroundStyle(.white)
        .activityBackgroundTint(Color(red: 0.07, green: 0.07, blue: 0.15))
        .activitySystemActionForegroundColor(.white)
    }
}

private struct TimerText: View {
    let state: RecordingActivityAttributes.ContentState
    /// A stale card's app is gone: freeze the clock at the last value it sent
    /// rather than keep counting up over a recording that is not happening.
    var isStale = false

    var body: some View {
        if state.isPaused || isStale {
            Text(Duration.seconds(state.elapsed)
                .formatted(.time(pattern: state.elapsed >= 3600 ? .hourMinuteSecond : .minuteSecond)))
                .monospacedDigit()
        } else {
            // Counts up on its own; trailing alignment because a timer Text
            // greedily claims width and would otherwise left-align.
            Text(state.startedAt, style: .timer)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct StatusBadge: View {
    let isPaused: Bool
    var isStale = false

    private var tint: Color {
        if isStale { return .secondary }
        return isPaused ? .orange : .red
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            // The app stopped refreshing this card: it can no longer claim a
            // recording is running, and saying so is the only cue the user
            // gets to reopen Minute.
            Text(isStale ? "Minute isn't running" : (isPaused ? "Paused" : "Recording"))
                .fontWeight(.semibold)
                .foregroundStyle(tint)
        }
    }
}

private struct StatusIcon: View {
    let isPaused: Bool

    var body: some View {
        Image(systemName: isPaused ? "pause.fill" : "waveform")
            .foregroundStyle(isPaused ? Color.orange : Color.red)
    }
}
