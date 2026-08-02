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

    @State private var player = AudioPlayerController()
    @State private var isGenerating = false
    @State private var summaryError: String?
    @State private var showingEditor = false
    @State private var confirmingDelete = false
    @State private var selectedTab: Tab = .summary

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
                    .disabled(meeting.summary == nil)
                    Button {
                        generateSummary()
                    } label: {
                        Label(meeting.summary == nil ? "Generate Summary" : "Regenerate Summary",
                              systemImage: "sparkles")
                    }
                    .disabled(!meeting.hasTranscript || isGenerating)
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
                player.stop()
                MeetingStore.delete(meeting, context: context)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The recording, transcript, and summary will be permanently deleted from this iPhone.")
        }
        .task {
            guard autoGenerateSummary, meeting.summary == nil, meeting.hasTranscript,
                  SummarizationService.availabilityMessage == nil else { return }
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
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(LinearGradient.brand)
                        Image(systemName: "waveform")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 42, height: 42)
                    .accessibilityHidden(true)

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
                        Text("Summarizing on device…")
                            .foregroundStyle(.secondary)
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
            if !summary.overview.isEmpty {
                Section {
                    Text(summary.overview)
                } header: {
                    Label("Overview", systemImage: "text.alignleft")
                }
            }
            bulletSection("Key Points", systemImage: "list.bullet", items: summary.keyPoints)
            bulletSection("Decisions", systemImage: "checkmark.seal", items: summary.decisions)
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
                } else if let unavailable = SummarizationService.availabilityMessage {
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
                                .foregroundStyle(.white)
                                .padding(.horizontal, 22)
                                .padding(.vertical, 11)
                                .background(LinearGradient.brand, in: Capsule())
                        }
                        .buttonStyle(PressableButtonStyle())
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
        Section {
            if meeting.hasTranscript {
                ForEach(Array(meeting.segments.enumerated()), id: \.offset) { _, segment in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(segment.start.clockString)
                            .font(.caption.monospacedDigit().weight(.medium))
                            .foregroundStyle(Color.accentColor)
                        Text(segment.text)
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
            if meeting.hasTranscript, player.isLoaded {
                Text("Tap a line to jump playback there.")
            }
        }
    }

    // MARK: - Actions

    private func generateSummary() {
        guard !isGenerating else { return }
        isGenerating = true
        summaryError = nil
        let transcript = meeting.transcriptText
        Task {
            do {
                let summary = try await SummarizationService().summarize(transcript: transcript)
                // The meeting may have been deleted while the model was working.
                if !meeting.isDeleted {
                    meeting.summary = summary
                    saveQuietly()
                }
            } catch {
                if !meeting.isDeleted {
                    summaryError = error.localizedDescription
                }
            }
            isGenerating = false
        }
    }

    private func saveQuietly() {
        do {
            try context.save()
        } catch {
            // The context autosaves; an explicit failure here isn't actionable for the user.
        }
    }
}
