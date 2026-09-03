import AVFoundation
import Foundation
import SwiftData

/// Owns the long-running per-meeting work — summarizing, re-transcribing, and
/// identifying speakers — app-wide, so leaving the meeting screen never
/// cancels or forgets a running job and coming back re-attaches to the same
/// progress.
///
/// One job per meeting at a time, enforced by the single `running` slot rather
/// than by the caller: all three rewrite the same `Meeting`, so two in flight
/// together let the later writer silently erase the earlier one's work. Keeping
/// the slot here (not in view state) is what makes the guard survive
/// navigation — view `@State` is destroyed when the screen is popped, while the
/// job keeps running.
@MainActor
@Observable
final class MeetingJobs {
    enum Kind {
        case summary
        case transcription
        case diarization
    }

    /// A failure whose message is already written for the user. Because
    /// `errorDescription` returns it, `localizedDescription` surfaces it
    /// verbatim and no special handling is needed at the catch site.
    struct JobMessage: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct Running {
        let kind: Kind
        let task: Task<Void, Never>
    }

    private struct Failure {
        let kind: Kind
        let message: String
    }

    private var running: [UUID: Running] = [:]
    private var statuses: [UUID: String] = [:]
    private var failures: [UUID: Failure] = [:]
    /// Meetings whose one automatic summary has been requested this run.
    private var autoSummaryClaimed: Set<UUID> = []

    /// Fired on the main actor after any job finishes successfully — the
    /// knowledge catch-up loop's nudge. Optional so tests and previews can
    /// leave it unset.
    var onContentChanged: (@MainActor () -> Void)?

    /// True while any job holds this meeting — the guard every entry point and
    /// every menu item shares.
    func isBusy(_ meeting: Meeting) -> Bool {
        running[meeting.id] != nil
    }

    func isRunning(_ kind: Kind, for meeting: Meeting) -> Bool {
        running[meeting.id]?.kind == kind
    }

    /// Progress text for whatever is running, e.g. "Reading part 2 of 7…".
    func status(for meeting: Meeting) -> String? {
        statuses[meeting.id]
    }

    /// The last failure for this meeting, but only when it came from `kind`, so
    /// each section of the detail view shows only its own error.
    func error(_ kind: Kind, for meeting: Meeting) -> String? {
        guard let failure = failures[meeting.id], failure.kind == kind else { return nil }
        return failure.message
    }

    func cancel(_ meeting: Meeting) {
        running[meeting.id]?.task.cancel()
    }

    /// Whether an automatic (post-save) summary may start now. True exactly
    /// once per meeting while the app runs, and never while that meeting's
    /// summary failure is showing: the detail view's `.task` re-runs on every
    /// re-appearance, and an automatic generation must not restart one the
    /// user stopped or wipe the error from one that failed. An explicit tap
    /// goes through `summarize` directly and is unaffected.
    func claimAutoSummary(for meeting: Meeting) -> Bool {
        guard !autoSummaryClaimed.contains(meeting.id), error(.summary, for: meeting) == nil else {
            return false
        }
        autoSummaryClaimed.insert(meeting.id)
        return true
    }

    // MARK: - Jobs

    @discardableResult
    func summarize(
        _ meeting: Meeting,
        template: SummaryTemplate,
        context: String,
        language: String?
    ) -> Task<Void, Never>? {
        let id = meeting.id
        let transcript = meeting.timestampedTranscriptText
        return start(.summary, for: meeting) { [self] in
            let summary = try await SummarizationEngines.current(language: language)
                .summarize(transcript: transcript, template: template, context: context) { status in
                    self.statuses[id] = status
                }
            // The meeting may have been deleted while the model was working.
            guard !meeting.isDeleted else { return }
            meeting.summary = summary
            applySuggestedTitleIfDefault(summary, to: meeting)
            try? meeting.modelContext?.save()
        }
    }

    @discardableResult
    func retranscribe(_ meeting: Meeting, audioAt url: URL) -> Task<Void, Never>? {
        start(.transcription, for: meeting) {
            let transcription = TranscriptionEngines.current()
            await transcription.prepare()
            if case .unavailable(let message) = transcription.availability {
                throw JobMessage(message: message)
            }
            let segments: [TranscriptSegment]
            do {
                let file = try AVAudioFile(forReading: url)
                segments = try await transcription.transcribe(file: file)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw JobMessage(message: "Re-transcription failed: \(error.localizedDescription)")
            }
            guard !meeting.isDeleted else { return }
            // A pass that produced nothing — the device language no longer
            // matching the audio, say — must not be mistaken for "this meeting
            // has no speech". Applying it would either destroy the only copy
            // the user has, or silently leave a transcript-less meeting
            // looking exactly as it did before they asked.
            guard !segments.isEmpty else {
                throw JobMessage(message: Self.noTextMessage(keptExistingTranscript: meeting.hasTranscript))
            }
            MeetingJobs.applyNewTranscript(segments, to: meeting)
            try? meeting.modelContext?.save()
        }
    }

    @discardableResult
    func identifySpeakers(_ meeting: Meeting, audioAt url: URL) -> Task<Void, Never>? {
        let id = meeting.id
        return start(.diarization, for: meeting) { [self] in
            let ranges = try await DiarizationService().diarize(audioAt: url) { status in
                self.statuses[id] = status
            }
            guard !meeting.isDeleted else { return }
            try MeetingJobs.applySpeakerIdentification(ranges, to: meeting)
            try? meeting.modelContext?.save()
        }
    }

    // MARK: - Plumbing

    /// Runs `work` as this meeting's job, or returns the running one when the
    /// meeting is already busy — so re-entering the screen attaches to the
    /// existing job instead of starting a second one. Status and in-flight
    /// bookkeeping are cleared however the work ends.
    @discardableResult
    private func start(
        _ kind: Kind,
        for meeting: Meeting,
        _ work: @escaping @MainActor () async throws -> Void
    ) -> Task<Void, Never>? {
        let id = meeting.id
        if let running = running[id] { return running.task }
        failures[id] = nil
        // Keep the app awake through brief app switches so the work isn't
        // suspended part-way through.
        let token = BackgroundTaskToken(name: "MeetingJobs")
        let task = Task { @MainActor [self] in
            do {
                try await work()
                onContentChanged?()
            } catch is CancellationError {
                // The user tapped Stop — nothing to report.
            } catch {
                if !meeting.isDeleted, !Task.isCancelled {
                    failures[id] = Failure(kind: kind, message: error.localizedDescription)
                }
            }
            statuses[id] = nil
            running[id] = nil
            token.end()
        }
        running[id] = Running(kind: kind, task: task)
        return task
    }

    /// Applies a fresh transcript: replaces segments, clears speaker names
    /// (indices point into the old segmentation — the confirmation dialog
    /// already promises the labels are cleared), and resets the knowledge
    /// extraction cursor so the changed transcript is re-extracted.
    static func applyNewTranscript(_ segments: [TranscriptSegment], to meeting: Meeting) {
        meeting.segments = segments
        meeting.speakerNames = nil
        meeting.knowledgeExtractedAt = nil
    }

    /// Applies diarization output: labels segments, drops names attached to
    /// the previous numbering (a fresh identification renumbers from
    /// scratch), and resets the extraction cursor so the Brain re-reads the
    /// meeting with speakers attributed. Throws when nothing was labeled, so
    /// the user hears that instead of watching the spinner vanish over an
    /// unchanged transcript.
    static func applySpeakerIdentification(_ ranges: [SpeakerRange], to meeting: Meeting) throws {
        let labeled = SpeakerAssignment.apply(ranges, to: meeting.segments)
        guard labeled.contains(where: { $0.speaker != nil }) else {
            throw JobMessage(message: "No distinct speakers could be identified in this recording.")
        }
        meeting.segments = labeled
        meeting.speakerNames = nil
        meeting.knowledgeExtractedAt = nil
    }

    /// Sets one speaker's display name. The Brain reads the transcript with
    /// names in it, so a rename resets the extraction cursor: facts about
    /// "Speaker 2" become facts about the person.
    static func applySpeakerName(_ name: String, at index: Int, to meeting: Meeting) {
        var names = meeting.speakerNames ?? []
        while names.count <= index {
            names.append("")
        }
        names[index] = name.trimmingCharacters(in: .whitespacesAndNewlines)
        meeting.speakerNames = names
        meeting.knowledgeExtractedAt = nil
    }

    /// Why an empty re-transcription is reported instead of applied. The
    /// language hint only applies to Apple Speech; Whisper auto-detects.
    static func noTextMessage(keptExistingTranscript: Bool) -> String {
        let kept = keptExistingTranscript ? ", so the existing transcript was kept" : ""
        let hint = AppSettings.transcriptionEngine == .appleSpeech
            ? " Check that the iPhone's language matches the language spoken in this meeting."
            : ""
        return "Re-transcription produced no text\(kept)." + hint
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
