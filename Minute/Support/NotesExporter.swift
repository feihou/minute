import Foundation

/// Builds the plain-text notes used by Copy and Share on the detail screen.
enum NotesExporter {
    static func notesText(for meeting: Meeting) -> String {
        var lines: [String] = []
        lines.append("# \(meeting.title)")
        lines.append(meeting.createdAt.formatted(date: .abbreviated, time: .shortened)
            + (meeting.duration > 0 ? " · \(meeting.duration.clockString)" : ""))

        if let summary = meeting.summary {
            // The app shows this caveat above the notes on screen. Copying or
            // sharing them without it hands someone a summary that silently
            // omits part of the meeting — and the iCloud Drive notes.md is the
            // copy most likely to be read months later, out of context.
            if let skipped = summary.skippedParts, skipped > 0 {
                lines.append("")
                lines.append("> Note: \(skipped) part\(skipped == 1 ? "" : "s") of the transcript couldn't be summarized, so these notes may be incomplete.")
            }
            if !summary.overview.isEmpty {
                lines.append("")
                lines.append("## Overview")
                lines.append(summary.overview)
            }
            for section in summary.sections ?? [] {
                appendSection(title: section.title, items: section.items, to: &lines)
            }
            appendSection(title: "Key Points", items: summary.keyPoints, to: &lines)
            appendSection(title: "Decisions", items: summary.decisions, to: &lines)
            if let perspectives = summary.speakerPerspectives, !perspectives.isEmpty {
                lines.append("")
                lines.append("## Speaker Perspectives")
                for perspective in perspectives {
                    lines.append("### \(perspective.speaker)")
                    lines.append(contentsOf: perspective.points.map { "- \($0)" })
                }
            }
            if !summary.actionItems.isEmpty {
                lines.append("")
                lines.append("## Action Items")
                for item in summary.actionItems {
                    lines.append("- \(item.task) (Owner: \(item.owner), Due: \(item.deadline))")
                }
            }
            appendSection(title: "Open Questions", items: summary.openQuestions, to: &lines)
        }

        if meeting.hasTranscript {
            lines.append("")
            lines.append("## Transcript")
            for segment in meeting.segments {
                let name = segment.speaker.map { "\(meeting.speakerName(for: $0)): " } ?? ""
                lines.append("[\(segment.start.clockString)] \(name)\(segment.text)")
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func appendSection(title: String, items: [String], to lines: inout [String]) {
        guard !items.isEmpty else { return }
        lines.append("")
        lines.append("## \(title)")
        for item in items {
            lines.append("- \(item)")
        }
    }
}
