import Foundation
import SwiftData

/// Owns in-flight summary generation app-wide, keyed by meeting, so leaving
/// the meeting screen never cancels or forgets a running generation — coming
/// back re-attaches to the same progress. One generation per meeting at a time.
@MainActor
@Observable
final class SummaryGeneration {
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var statuses: [UUID: String] = [:]
    private var errors: [UUID: String] = [:]

    func isGenerating(_ meeting: Meeting) -> Bool {
        tasks[meeting.id] != nil
    }

    func status(for meeting: Meeting) -> String? {
        statuses[meeting.id]
    }

    /// The last generation failure for this meeting; cleared when a new
    /// generation starts.
    func error(for meeting: Meeting) -> String? {
        errors[meeting.id]
    }

    func cancel(_ meeting: Meeting) {
        tasks[meeting.id]?.cancel()
    }

    /// Starts summarizing; returns the already-running task when this meeting
    /// is being summarized, so re-entering the screen can't double-generate.
    @discardableResult
    func generate(
        _ meeting: Meeting,
        template: SummaryTemplate,
        context: String,
        language: String?
    ) -> Task<Void, Never>? {
        let id = meeting.id
        if let running = tasks[id] { return running }
        errors[id] = nil
        let transcript = meeting.timestampedTranscriptText
        // Keep the app awake through brief app switches so the model isn't
        // suspended mid-chunk.
        let token = BackgroundTaskToken(name: "SummaryGeneration")
        let task = Task {
            do {
                let summary = try await SummarizationService(language: language)
                    .summarize(transcript: transcript, template: template, context: context) { [weak self] status in
                        self?.statuses[id] = status
                    }
                // The meeting may have been deleted while the model was working.
                if !meeting.isDeleted {
                    meeting.summary = summary
                    applySuggestedTitleIfDefault(summary, to: meeting)
                    try? meeting.modelContext?.save()
                }
            } catch is CancellationError {
                // The user tapped Stop — nothing to report.
            } catch {
                if !meeting.isDeleted, !Task.isCancelled {
                    errors[id] = error.localizedDescription
                }
            }
            statuses[id] = nil
            tasks[id] = nil
            token.end()
        }
        tasks[id] = task
        return task
    }

    /// Adopts the model's title only while the meeting still carries the
    /// default "Meeting <date>" name — never over a user-chosen title. The
    /// stored default is authoritative; re-deriving it is only a fallback for
    /// meetings saved before the default was persisted, and can miss when the
    /// locale or time zone changed since then.
    private func applySuggestedTitleIfDefault(_ summary: MeetingSummary, to meeting: Meeting) {
        guard let suggested = summary.suggestedTitle else { return }
        let baseline = meeting.defaultTitle ?? RecordingSession.defaultTitle(for: meeting.createdAt)
        guard meeting.title == baseline else { return }
        meeting.title = suggested
    }
}
