import SwiftData
import SwiftUI
import UIKit

/// Everything about one meeting: playback, summary sections, transcript,
/// and edit/copy/share/delete.
struct MeetingDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var meeting: Meeting

    @State private var player = AudioPlayerController()
    @State private var isGenerating = false
    @State private var summaryError: String?
    @State private var showingEditor = false
    @State private var confirmingDelete = false

    var body: some View {
        List {
            Section("Title") {
                TextField("Title", text: $meeting.title)
                    .accessibilityLabel("Meeting title")
            }

            if let url = MeetingStore.audioURL(for: meeting) {
                Section("Recording") {
                    PlaybackBarView(player: player, url: url)
                }
            }

            summaryContent

            transcriptSection
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
        .onDisappear {
            player.stop()
            saveQuietly()
        }
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
                Section("Overview") {
                    Text(summary.overview)
                }
            }
            bulletSection("Key Points", items: summary.keyPoints)
            bulletSection("Decisions", items: summary.decisions)
            if !summary.actionItems.isEmpty {
                Section("Action Items") {
                    ForEach(Array(summary.actionItems.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.task)
                            Text("Owner: \(item.owner) · Due: \(item.deadline)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            bulletSection("Open Questions", items: summary.openQuestions)
        } else if !isGenerating {
            Section("Summary") {
                if !meeting.hasTranscript {
                    Text("No transcript was captured for this meeting, so a summary can't be generated.")
                        .foregroundStyle(.secondary)
                } else if let unavailable = SummarizationService.availabilityMessage {
                    Text(unavailable)
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        generateSummary()
                    } label: {
                        Label("Generate Summary", systemImage: "sparkles")
                    }
                }
            }
        }
    }

    @ViewBuilder private func bulletSection(_ title: String, items: [String]) -> some View {
        if !items.isEmpty {
            Section(title) {
                // Offsets, not \.self — edited lists can contain duplicates.
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Label {
                        Text(item)
                    } icon: {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 5))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Transcript

    @ViewBuilder private var transcriptSection: some View {
        Section("Transcript") {
            if meeting.hasTranscript {
                ForEach(Array(meeting.segments.enumerated()), id: \.offset) { _, segment in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(segment.start.clockString)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
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
