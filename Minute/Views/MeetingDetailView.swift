import SwiftData
import SwiftUI
import UIKit

/// Everything about one meeting: playback, summary, transcript, and
/// edit/copy/share/delete — laid out as a single reading surface rather than a
/// stack of cards, so the notes read like a document instead of a form.
struct MeetingDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var meeting: Meeting
    /// Kick off summary generation as soon as the view appears (used right
    /// after a recording finishes when Auto-Summarize is on in Settings).
    var autoGenerateSummary = false

    private enum Tab {
        case summary
        case transcript
    }

    /// App-level owner of running work — summarization, re-transcription, and
    /// speaker identification all survive navigating away from this screen and
    /// re-attach on return. Deliberately not view `@State`: that is destroyed
    /// when the screen is popped, which would reset the guards below while the
    /// job kept running.
    @Environment(MeetingJobs.self) private var jobs

    @State private var player = AudioPlayerController()
    @State private var showingEditor = false
    @State private var confirmingDelete = false
    @State private var confirmingRetranscribe = false
    @State private var deleteFailed = false
    @State private var renamingSpeaker: Int?
    @State private var renameText = ""
    @State private var selectedTab: Tab = .summary
    @AppStorage(AppSettings.summaryTemplateKey) private var summaryTemplateID = SummaryTemplate.standard.id
    @Query private var knowledgeEntities: [KnowledgeEntity]

    /// Participants this brain already knows — the pre-meeting brief.
    private var briefEntities: [KnowledgeEntity] {
        KnowledgeBrief.matchedEntities(speakerNames: meeting.speakerNames, entities: knowledgeEntities)
    }

    /// Brief entities paired with the facts worth showing for them — facts
    /// from other meetings only. Entities left with nothing to show (every
    /// fact came from this meeting) are dropped rather than rendered empty.
    private var briefContent: [(entity: KnowledgeEntity, facts: [KnowledgeFact])] {
        briefEntities.compactMap { entity in
            let facts = KnowledgeBrief.briefFacts(for: entity, excludingMeetingID: meeting.id)
            return facts.isEmpty ? nil : (entity, facts)
        }
    }

    /// True while any job holds this meeting; every menu item that rewrites the
    /// meeting is gated on it.
    private var isBusy: Bool { jobs.isBusy(meeting) }
    private var isGenerating: Bool { jobs.isRunning(.summary, for: meeting) }
    private var isRetranscribing: Bool { jobs.isRunning(.transcription, for: meeting) }
    private var isDiarizing: Bool { jobs.isRunning(.diarization, for: meeting) }
    /// Progress text for whichever job is running; only one ever is.
    private var jobStatus: String? { jobs.status(for: meeting) }
    private var summaryError: String? { jobs.error(.summary, for: meeting) }
    private var transcriptError: String? { jobs.error(.transcription, for: meeting) }
    private var diarizationError: String? { jobs.error(.diarization, for: meeting) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                masthead
                briefSection
                tabPicker
                switch selectedTab {
                case .summary:
                    summaryContent
                case .transcript:
                    transcriptContent
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Layout.margin)
            .padding(.bottom, 56)
        }
        // Both edges: the notes run under the navigation bar at the top and
        // under the tab bar at the bottom, and a hard cut at either one reads
        // as clipped text rather than as more page below.
        .scrollEdgeEffectStyle(.soft, for: .all)
        .navigationTitle(meeting.createdAt.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        UIPasteboard.general.string = NotesExporter.notesText(for: meeting)
                    } label: {
                        Label("Copy Notes", systemImage: "doc.on.doc")
                    }
                    ShareLink(item: NotesExporter.notesText(for: meeting)) {
                        Label("Share Notes", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        showingEditor = true
                    } label: {
                        Label("Edit Summary", systemImage: "pencil")
                    }
                    // Blocked while other work is running: the editor snapshots
                    // the current summary, and a generation landing while it is
                    // open would swap the notes out from under the user's edits.
                    .disabled(meeting.summary == nil || isBusy)
                    Button {
                        generateSummary()
                    } label: {
                        Label(meeting.summary == nil ? "Generate Summary" : "Regenerate Summary",
                              systemImage: "sparkles")
                    }
                    // Also blocked during re-transcription: summarizing a
                    // transcript that's being replaced would save notes for
                    // text the user never sees again.
                    .disabled(!meeting.hasTranscript || isBusy)
                    Picker(selection: $summaryTemplateID) {
                        ForEach(SummaryTemplate.all) { template in
                            Text(template.name).tag(template.id)
                        }
                    } label: {
                        Label("Summary Template", systemImage: "square.grid.2x2")
                    }
                    .disabled(isBusy)
                    Button {
                        confirmingRetranscribe = true
                    } label: {
                        Label("Re-transcribe Audio", systemImage: "arrow.clockwise")
                    }
                    .disabled(MeetingStore.audioURL(for: meeting) == nil || isBusy)
                    Button {
                        identifySpeakers()
                    } label: {
                        Label(meeting.hasSpeakers ? "Re-identify Speakers" : "Identify Speakers",
                              systemImage: "person.2.wave.2")
                    }
                    .disabled(MeetingStore.audioURL(for: meeting) == nil || !meeting.hasTranscript || isBusy)
                    Divider()
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Label("Delete Meeting", systemImage: "trash")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingEditor) {
            SummaryEditorView(meeting: meeting)
        }
        .confirmationDialog(
            "Delete this meeting?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Meeting", role: .destructive) {
                // Only leave once the delete is actually committed — dismissing
                // on a failed delete tells the user their meeting is gone while
                // it is still in the library. Playback is torn down only on
                // that same success: stopping first would leave the retained
                // screen showing controls wired to an unloaded player, because
                // PlaybackBarView's .task(id: url) has already run and the URL
                // has not changed.
                if MeetingStore.delete(meeting, context: context) {
                    player.stop()
                    dismiss()
                } else {
                    deleteFailed = true
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The recording, transcript, summary, and everything Brain learned from this meeting will be permanently deleted from this iPhone.")
        }
        .alert("This meeting couldn't be deleted", isPresented: $deleteFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Storage may be full or unavailable. Free up space and try again.")
        }
        .confirmationDialog(
            "Re-transcribe this meeting?",
            isPresented: $confirmingRetranscribe,
            titleVisibility: .visible
        ) {
            Button("Replace Transcript") {
                retranscribe()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current transcript will be replaced using the on-device speech model. Speaker labels are cleared, and the summary stays until you regenerate it.")
        }
        .alert("Rename Speaker", isPresented: isRenamingSpeakerPresented, presenting: renamingSpeaker) { index in
            TextField("Name", text: $renameText)
            Button("Save") { renameSpeaker(index, to: renameText) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Used on this speaker's transcript lines and in newly generated summaries.")
        }
        .task {
            guard meeting.summary == nil, meeting.hasTranscript,
                  SummarizationEngines.availabilityMessage == nil else { return }
            if autoGenerateSummary {
                generateSummary()
            } else {
                // The user will probably tap Generate; start loading the
                // model now so the tap doesn't pay the model-load wait too.
                SummarizationEngines.prewarm(language: AppSettings.summaryLanguage)
            }
        }
        .onDisappear {
            player.stop()
            saveQuietly()
        }
    }

    // MARK: - Masthead

    /// The meeting's own title is the headline of the page, so it is set at
    /// display size and its details collapse into one quiet line — three
    /// separate chips restated what the line already says.
    private var masthead: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Title", text: $meeting.title, axis: .vertical)
                .font(.largeTitle.bold())
                .textFieldStyle(.plain)
                .accessibilityLabel("Meeting title")

            Text(metaLine)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let url = MeetingStore.audioURL(for: meeting) {
                PlaybackBarView(player: player, url: url)
                    .padding(.top, 8)
            }
        }
        .padding(.top, 6)
    }

    private var metaLine: String {
        var parts = [meeting.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())]
        if meeting.duration > 0 {
            parts.append(meeting.duration.clockString)
        }
        parts.append("On device")
        return parts.joined(separator: "  ·  ")
    }

    // MARK: - Section scaffolding

    /// One block on the reading surface: a quiet heading, then its content.
    /// The generous leading gap is what separates blocks — no card edges, no
    /// rules.
    private func block<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Layout.headingGap) {
            SectionHeading(title)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Layout.sectionGap)
    }

    private var tabPicker: some View {
        Picker("Section", selection: $selectedTab) {
            Text("Summary").tag(Tab.summary)
            Text("Transcript").tag(Tab.transcript)
        }
        .pickerStyle(.segmented)
        .padding(.top, Layout.sectionGap - 4)
    }

    // MARK: - Brief

    @ViewBuilder private var briefSection: some View {
        if !briefContent.isEmpty {
            block("What You Know") {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(briefContent, id: \.entity.id) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.entity.name)
                                .font(.subheadline.weight(.semibold))
                            ForEach(item.facts) { fact in
                                BulletRow(tint: .secondary) {
                                    Text(fact.text).font(.footnote)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Summary

    @ViewBuilder private var summaryContent: some View {
        // Progress and errors stay visible for regeneration too, when a
        // summary already exists below.
        if isGenerating {
            HStack(spacing: 12) {
                ProgressView()
                Text(jobStatus ?? "Summarizing on device…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Stop") {
                    jobs.cancel(meeting)
                }
                .font(.subheadline.weight(.medium))
                .buttonStyle(.borderless)
            }
            .padding(.top, Layout.sectionGap - 8)
        }
        if let summaryError {
            notice(summaryError, systemImage: "exclamationmark.triangle.fill", tint: .red)
                .padding(.top, Layout.sectionGap - 10)
        }

        if let summary = meeting.summary {
            if let skipped = summary.skippedParts, skipped > 0 {
                notice(
                    "\(skipped) part\(skipped == 1 ? "" : "s") of the transcript couldn't be summarized, so these notes may be incomplete. Regenerating may recover them.",
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .orange
                )
                .padding(.top, Layout.sectionGap - 10)
            }
            if !summary.overview.isEmpty {
                block("Overview") {
                    Text(summary.overview)
                        .lineSpacing(4)
                }
            }
            if let sections = summary.sections {
                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    bulletBlock(section.title, items: section.items)
                }
            }
            bulletBlock("Key Points", items: summary.keyPoints)
            bulletBlock("Decisions", items: summary.decisions)
            if let perspectives = summary.speakerPerspectives, !perspectives.isEmpty {
                block("Speaker Perspectives") {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(Array(perspectives.enumerated()), id: \.offset) { _, perspective in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(perspective.speaker)
                                    .font(.subheadline.weight(.semibold))
                                ForEach(Array(perspective.points.enumerated()), id: \.offset) { _, point in
                                    BulletRow(point)
                                }
                            }
                        }
                    }
                }
            }
            if !summary.actionItems.isEmpty {
                block("Action Items") {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(summary.actionItems.enumerated()), id: \.offset) { _, item in
                            actionItemRow(item)
                        }
                    }
                }
            }
            bulletBlock("Open Questions", items: summary.openQuestions)
        } else if !isGenerating {
            emptySummaryState
                .padding(.top, Layout.sectionGap)
        }
    }

    @ViewBuilder private var emptySummaryState: some View {
        if !meeting.hasTranscript {
            Text("No transcript was captured for this meeting, so a summary can't be generated.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if let unavailable = SummarizationEngines.availabilityMessage {
            Text(unavailable)
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.title)
                    .foregroundStyle(Color.accentColor)
                Text("Turn this meeting into key points, decisions, and action items — entirely on device.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    generateSummary()
                } label: {
                    Label("Generate Summary", systemImage: "sparkles")
                        .font(.headline)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
    }

    @ViewBuilder private func bulletBlock(_ title: String, items: [String]) -> some View {
        if !items.isEmpty {
            block(title) {
                VStack(alignment: .leading, spacing: Layout.itemGap) {
                    // Offsets, not \.self — edited lists can contain duplicates.
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        BulletRow(item)
                    }
                }
            }
        }
    }

    private func actionItemRow(_ item: ActionItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.body)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.task)
                if let detail = ownerAndDeadline(item) {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// "Priya  ·  Friday" — the owner and due date as a caption under the task
    /// rather than two more pill-shaped chips.
    private func ownerAndDeadline(_ item: ActionItem) -> String? {
        let parts = [item.owner, item.deadline].filter { $0 != ActionItem.notSpecified && !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    /// Inline warning or error. Tinted text on a matching wash — loud enough to
    /// catch, quiet enough not to become the page's focal point.
    private func notice(_ text: String, systemImage: String, tint: Color) -> some View {
        Label {
            Text(text).font(.footnote)
        } icon: {
            Image(systemName: systemImage).font(.footnote)
        }
        .foregroundStyle(tint)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Transcript

    @ViewBuilder private var transcriptContent: some View {
        if isRetranscribing || isDiarizing {
            HStack(spacing: 12) {
                ProgressView()
                Text(isRetranscribing ? "Re-transcribing on device…" : (jobStatus ?? "Identifying speakers on device…"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, Layout.sectionGap - 8)
        }
        if let transcriptError {
            notice(transcriptError, systemImage: "exclamationmark.triangle.fill", tint: .red)
                .padding(.top, Layout.sectionGap - 10)
        }
        if let diarizationError {
            notice(diarizationError, systemImage: "exclamationmark.triangle.fill", tint: .red)
                .padding(.top, Layout.sectionGap - 10)
        }

        if meeting.hasTranscript {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(Array(meeting.segments.enumerated()), id: \.offset) { _, segment in
                    transcriptRow(segment)
                }
            }
            .padding(.top, Layout.sectionGap - 6)

            if let hint = transcriptHint {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 24)
            }
        } else {
            Text("No transcript was captured for this meeting.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, Layout.sectionGap)
        }
    }

    /// Speaker and timestamp ride above the line rather than beside it, so the
    /// spoken text keeps a single straight left edge all the way down.
    private func transcriptRow(_ segment: TranscriptSegment) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                if let speaker = segment.speaker {
                    Button {
                        beginRenamingSpeaker(speaker)
                    } label: {
                        Text(meeting.speakerName(for: speaker))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Self.speakerColor(for: speaker))
                    }
                    .buttonStyle(.borderless)
                    // Re-transcribing and re-identifying both discard the
                    // speaker numbering, so a name typed while one is running
                    // would be wiped the moment it finished.
                    .disabled(isBusy)
                    .accessibilityLabel("Rename \(meeting.speakerName(for: speaker))")
                }
                Text(segment.start.clockString)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Text(segment.text)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            if player.isLoaded {
                player.seek(to: segment.start)
                player.play()
            }
        }
    }

    private var transcriptHint: String? {
        let hints = [
            player.isLoaded ? "Tap a line to jump playback there." : nil,
            meeting.hasSpeakers ? "Tap a name to rename that speaker." : nil,
        ].compactMap(\.self)
        return hints.isEmpty ? nil : hints.joined(separator: " ")
    }

    // MARK: - Actions

    // Each of these is a no-op while the meeting is busy — MeetingJobs enforces
    // that itself, so re-entering this screen mid-job can't start a second one.

    private func generateSummary() {
        jobs.summarize(
            meeting,
            template: SummaryTemplate.template(for: summaryTemplateID),
            context: AppSettings.summaryContext,
            language: AppSettings.summaryLanguage
        )
    }

    private func retranscribe() {
        guard let url = MeetingStore.audioURL(for: meeting) else { return }
        selectedTab = .transcript
        jobs.retranscribe(meeting, audioAt: url)
    }

    private func identifySpeakers() {
        guard let url = MeetingStore.audioURL(for: meeting) else { return }
        selectedTab = .transcript
        jobs.identifySpeakers(meeting, audioAt: url)
    }

    private func beginRenamingSpeaker(_ index: Int) {
        if let names = meeting.speakerNames, names.indices.contains(index) {
            renameText = names[index]
        } else {
            renameText = ""
        }
        renamingSpeaker = index
    }

    private func renameSpeaker(_ index: Int, to name: String) {
        var names = meeting.speakerNames ?? []
        while names.count <= index {
            names.append("")
        }
        names[index] = name.trimmingCharacters(in: .whitespacesAndNewlines)
        meeting.speakerNames = names
        saveQuietly()
    }

    private var isRenamingSpeakerPresented: Binding<Bool> {
        Binding(
            get: { renamingSpeaker != nil },
            set: { if !$0 { renamingSpeaker = nil } }
        )
    }

    /// Stable per-speaker tint for transcript labels.
    private static let speakerColors: [Color] = [.blue, .orange, .purple, .green, .pink, .teal]

    static func speakerColor(for index: Int) -> Color {
        speakerColors[index % speakerColors.count]
    }

    private func saveQuietly() {
        do {
            try context.save()
        } catch {
            // The context autosaves; an explicit failure here isn't actionable for the user.
        }
    }
}
