import SwiftData
import SwiftUI
import UIKit

/// Everything about one meeting: playback, summary, transcript, and
/// edit/copy/share/delete — organized as a header card plus tabbed content.
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
        List {
            headerSection

            Section {
                Picker("Section", selection: $selectedTab) {
                    Text("Summary").tag(Tab.summary)
                    Text("Transcript").tag(Tab.transcript)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            switch selectedTab {
            case .summary:
                summaryContent
            case .transcript:
                transcriptSection
            }
        }
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
            Text("The recording, transcript, and summary will be permanently deleted from this iPhone.")
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
            guard autoGenerateSummary, meeting.summary == nil, meeting.hasTranscript,
                  SummarizationEngines.availabilityMessage == nil else { return }
            generateSummary()
        }
        .onDisappear {
            player.stop()
            saveQuietly()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    BrandIconTile(size: 42, cornerRadius: 10, iconSize: 17)

                    TextField("Title", text: $meeting.title, axis: .vertical)
                        .font(.title3.bold())
                        .accessibilityLabel("Meeting title")
                }

                // Falls back to a vertical stack when the chips can't fit
                // (large Dynamic Type, narrow devices, long localized dates).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { metaChips }
                    VStack(alignment: .leading, spacing: 8) { metaChips }
                }

                if let url = MeetingStore.audioURL(for: meeting) {
                    PlaybackBarView(player: player, url: url)
                }
            }
            .padding(.vertical, 6)
        }

    }

    @ViewBuilder private var metaChips: some View {
        metaChip("calendar", meeting.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
        if meeting.duration > 0 {
            metaChip("clock", meeting.duration.clockString)
        }
        metaChip("lock.fill", "On device")
    }

    private func metaChip(_ systemImage: String, _ text: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(.secondarySystemFill).opacity(0.6), in: Capsule())
    }

    // MARK: - Summary

    @ViewBuilder private var summaryContent: some View {
        // Progress and errors stay visible for regeneration too, when a
        // summary already exists below.
        if isGenerating || summaryError != nil {
            Section {
                if isGenerating {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(jobStatus ?? "Summarizing on device…")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Stop") {
                            jobs.cancel(meeting)
                        }
                        .buttonStyle(.borderless)
                        .font(.subheadline.weight(.medium))
                    }
                }
                if let summaryError {
                    Text(summaryError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        if let summary = meeting.summary {
            if let skipped = summary.skippedParts, skipped > 0 {
                Section {
                    Label(
                        "\(skipped) part\(skipped == 1 ? "" : "s") of the transcript couldn't be summarized, so these notes may be incomplete. Regenerating may recover them.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }
            }
            if !summary.overview.isEmpty {
                Section {
                    Text(summary.overview)
                } header: {
                    Label("Overview", systemImage: "text.alignleft")
                }
            }
            if let sections = summary.sections {
                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    bulletSection(section.title, systemImage: "list.bullet", items: section.items)
                }
            }
            bulletSection("Key Points", systemImage: "list.bullet", items: summary.keyPoints)
            bulletSection("Decisions", systemImage: "checkmark.seal", items: summary.decisions)
            if let perspectives = summary.speakerPerspectives, !perspectives.isEmpty {
                Section {
                    ForEach(Array(perspectives.enumerated()), id: \.offset) { _, perspective in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(perspective.speaker)
                                .font(.subheadline.weight(.semibold))
                            ForEach(Array(perspective.points.enumerated()), id: \.offset) { _, point in
                                Label {
                                    Text(point)
                                } icon: {
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 5))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Label("Speaker Perspectives", systemImage: "person.2")
                }
            }
            if !summary.actionItems.isEmpty {
                Section {
                    ForEach(Array(summary.actionItems.enumerated()), id: \.offset) { _, item in
                        actionItemRow(item)
                    }
                } header: {
                    Label("Action Items", systemImage: "flag")
                }
            }
            bulletSection("Open Questions", systemImage: "questionmark.circle", items: summary.openQuestions)
        } else if !isGenerating {
            Section {
                if !meeting.hasTranscript {
                    Text("No transcript was captured for this meeting, so a summary can't be generated.")
                        .foregroundStyle(.secondary)
                } else if let unavailable = SummarizationEngines.availabilityMessage {
                    Text(unavailable)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "sparkles")
                            .font(.title2)
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
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private func actionItemRow(_ item: ActionItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(Color.accentColor)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.task)
                if item.owner != ActionItem.notSpecified || item.deadline != ActionItem.notSpecified {
                    HStack(spacing: 6) {
                        if item.owner != ActionItem.notSpecified {
                            metaChip("person", item.owner)
                        }
                        if item.deadline != ActionItem.notSpecified {
                            metaChip("calendar.badge.clock", item.deadline)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func bulletSection(_ title: String, systemImage: String, items: [String]) -> some View {
        if !items.isEmpty {
            Section {
                // Offsets, not \.self — edited lists can contain duplicates.
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Label {
                        Text(item)
                    } icon: {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 5))
                            .foregroundStyle(Color.accentColor)
                    }
                }
            } header: {
                Label(title, systemImage: systemImage)
            }
        }
    }

    // MARK: - Transcript

    @ViewBuilder private var transcriptSection: some View {
        if isRetranscribing || isDiarizing || transcriptError != nil || diarizationError != nil {
            Section {
                if isRetranscribing {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Re-transcribing on device…")
                            .foregroundStyle(.secondary)
                    }
                }
                if isDiarizing {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(jobStatus ?? "Identifying speakers on device…")
                            .foregroundStyle(.secondary)
                    }
                }
                if let transcriptError {
                    Text(transcriptError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                if let diarizationError {
                    Text(diarizationError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        Section {
            if meeting.hasTranscript {
                ForEach(Array(meeting.segments.enumerated()), id: \.offset) { _, segment in
                    VStack(alignment: .leading, spacing: 3) {
                        if let speaker = segment.speaker {
                            Button {
                                beginRenamingSpeaker(speaker)
                            } label: {
                                Text(meeting.speakerName(for: speaker))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Self.speakerColor(for: speaker))
                            }
                            .buttonStyle(.borderless)
                            // Re-transcribing and re-identifying both discard
                            // the speaker numbering, so a name typed while one
                            // is running would be wiped the moment it finished.
                            .disabled(isBusy)
                            .accessibilityLabel("Rename \(meeting.speakerName(for: speaker))")
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(segment.start.clockString)
                                .font(.caption.monospacedDigit().weight(.medium))
                                .foregroundStyle(Color.accentColor)
                            Text(segment.text)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if player.isLoaded {
                            player.seek(to: segment.start)
                            player.play()
                        }
                    }
                }
            } else {
                Text("No transcript was captured for this meeting.")
                    .foregroundStyle(.secondary)
            }
        } footer: {
            let hints = [
                meeting.hasTranscript && player.isLoaded ? "Tap a line to jump playback there." : nil,
                meeting.hasSpeakers ? "Tap a name to rename that speaker." : nil,
            ].compactMap(\.self)
            if !hints.isEmpty {
                Text(hints.joined(separator: " "))
            }
        }
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
