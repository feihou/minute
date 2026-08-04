import SwiftUI
import WidgetKit

struct MinuteWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct MinuteWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> MinuteWidgetEntry {
        MinuteWidgetEntry(date: .now, snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (MinuteWidgetEntry) -> Void) {
        completion(MinuteWidgetEntry(date: .now, snapshot: context.isPreview ? .sample : WidgetSnapshotStore().load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MinuteWidgetEntry>) -> Void) {
        let entry = MinuteWidgetEntry(date: .now, snapshot: WidgetSnapshotStore().load())
        completion(Timeline(entries: [entry], policy: .never))
    }
}

private extension WidgetSnapshot {
    static let sample = WidgetSnapshot(meetings: [
        WidgetMeeting(id: UUID(), title: "Product review", createdAt: .now.addingTimeInterval(-900), duration: 2_145),
        WidgetMeeting(id: UUID(), title: "Weekly sync", createdAt: .now.addingTimeInterval(-86_400), duration: 1_820),
    ])
}

struct MinuteHomeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetConstants.widgetKind, provider: MinuteWidgetProvider()) { entry in
            MinuteHomeWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color(.systemBackground) }
        }
        .configurationDisplayName("Quick Record & Recents")
        .description("Start a recording and return to recent meetings.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct MinuteHomeWidgetView: View {
    let entry: MinuteWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemMedium:
            MediumMinuteWidgetView(meetings: entry.snapshot.meetings)
        default:
            SmallMinuteWidgetView(latest: entry.snapshot.meetings.first)
        }
    }
}

private struct WidgetIconTile: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "waveform")
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient.brand,
                in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            )
            .widgetAccentable()
    }
}

private struct SmallMinuteWidgetView: View {
    let latest: WidgetMeeting?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                WidgetIconTile(size: 30)
                Text("Minute")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
            }
            Spacer(minLength: 4)
            Label("New Meeting", systemImage: "mic.fill")
                .font(.headline)
                .foregroundStyle(Color.accentColor)
                .widgetAccentable()
            Text("Open Minute to record")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Divider()
            if let latest {
                Text(latest.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(metadataText(for: latest))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Recent meetings appear here")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .widgetURL(MinuteDeepLink.newMeeting.url)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilitySummary))
        .accessibilityHint("Opens Minute before recording begins")
    }

    private var accessibilitySummary: String {
        if let latest {
            return "New Meeting. Latest meeting: \(latest.title), \(metadataText(for: latest))"
        }
        return "New Meeting. No recent meetings"
    }
}

private struct MediumMinuteWidgetView: View {
    let meetings: [WidgetMeeting]

    var body: some View {
        HStack(spacing: 12) {
            Link(destination: MinuteDeepLink.newMeeting.url) {
                VStack(alignment: .leading, spacing: 7) {
                    WidgetIconTile(size: 40)
                    Spacer(minLength: 0)
                    Label("New Meeting", systemImage: "mic.fill")
                        .font(.headline)
                        .foregroundStyle(Color.accentColor)
                        .widgetAccentable()
                    Text("Open Minute to record")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: 108)
            .accessibilityHint("Opens Minute before recording begins")

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                Text("Recent meetings")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if meetings.isEmpty {
                    Spacer(minLength: 0)
                    Text("Your recent meetings will appear here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                } else {
                    ForEach(Array(meetings.prefix(3))) { meeting in
                        Link(destination: MinuteDeepLink.meeting(meeting.id).url) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(meeting.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(metadataText(for: meeting))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("\(meeting.title), \(metadataText(for: meeting))"))
                        .accessibilityHint("Opens this meeting in Minute")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private func metadataText(for meeting: WidgetMeeting) -> String {
    let date = meeting.createdAt.formatted(date: .abbreviated, time: .shortened)
    guard meeting.duration > 0 else { return date }
    return "\(date) · \(durationText(meeting.duration))"
}

private func durationText(_ duration: TimeInterval) -> String {
    Duration.seconds(duration.rounded())
        .formatted(.time(pattern: duration >= 3_600 ? .hourMinuteSecond : .minuteSecond))
}
