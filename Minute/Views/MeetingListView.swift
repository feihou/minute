import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct MeetingListView: View {
    var storeIsEphemeral = false

    @Environment(\.modelContext) private var context
    @Query(sort: \Meeting.createdAt, order: .reverse) private var meetings: [Meeting]

    @State private var searchText = ""
    @State private var draftTitle = ""
    @State private var showingNewMeeting = false
    @State private var showingSettings = false
    @State private var activeSession: RecordingSession?
    @State private var justFinished: Meeting?
    @State private var didSweepOrphans = false
    @State private var showingImporter = false
    @State private var importingFileName: String?
    @State private var importTask: Task<Void, Never>?
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            Group {
                if meetings.isEmpty {
                    emptyState
                } else {
                    meetingList
                }
            }
            .navigationTitle("Minute")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingImporter = true
                    } label: {
                        Label("Import Audio", systemImage: "square.and.arrow.down")
                    }
                    .disabled(importingFileName != nil)
                }
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.audio]) { result in
                switch result {
                case .success(let url):
                    startImport(url)
                case .failure(let error):
                    // Some providers report the picker's own Cancel as an
                    // error — that's not a failure worth alerting. Real
                    // failures (e.g. the file couldn't be materialized)
                    // must surface, or the tap looks like it did nothing.
                    let isUserCancel = error is CancellationError
                        || (error as? CocoaError)?.code == .userCancelled
                    if !isUserCancel {
                        importError = error.localizedDescription
                    }
                }
            }
            .alert("Import Failed", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
            .safeAreaInset(edge: .top) {
                if let importingFileName {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Importing \(importingFileName)…")
                            .font(.footnote)
                            .lineLimit(1)
                        Spacer()
                        Button("Cancel") {
                            importTask?.cancel()
                        }
                        .font(.footnote.weight(.medium))
                    }
                    .padding(10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal)
                }
            }
            .navigationDestination(item: $justFinished) { meeting in
                MeetingDetailView(meeting: meeting, autoGenerateSummary: AppSettings.autoSummarizeEnabled)
            }
            .safeAreaInset(edge: .bottom) {
                if !meetings.isEmpty {
                    recordButton
                        .padding(.bottom, 6)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if storeIsEphemeral {
                Label("Storage is unavailable — meetings from this session won't be kept after the app closes.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(.yellow.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal)
            }
        }
        .task {
            // Clean up audio left behind by a crash mid-recording — but never
            // while running on the fallback store, where meetings that
            // reference these files may still exist in the real database.
            guard !storeIsEphemeral, !didSweepOrphans else { return }
            didSweepOrphans = true
            MeetingStore.removeOrphanedAudio(referencedFileNames: Set(meetings.compactMap(\.audioFileName)))
        }
        .sheet(isPresented: $showingNewMeeting) {
            NewMeetingSheet(title: $draftTitle) {
                activeSession = RecordingSession(title: draftTitle)
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .fullScreenCover(item: $activeSession) { session in
            RecordingView(session: session) { finished in
                activeSession = nil
                if let finished {
                    justFinished = finished
                }
            }
        }
    }

    // MARK: - List

    private var meetingList: some View {
        List {
            ForEach(groupedMeetings, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.items) { meeting in
                        NavigationLink {
                            MeetingDetailView(meeting: meeting)
                        } label: {
                            MeetingRowView(meeting: meeting)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                MeetingStore.delete(meeting, context: context)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button {
                                UIPasteboard.general.string = NotesExporter.notesText(for: meeting)
                            } label: {
                                Label("Copy Notes", systemImage: "doc.on.doc")
                            }
                            ShareLink(item: NotesExporter.notesText(for: meeting)) {
                                Label("Share Notes", systemImage: "square.and.arrow.up")
                            }
                            Divider()
                            Button(role: .destructive) {
                                MeetingStore.delete(meeting, context: context)
                            } label: {
                                Label("Delete Meeting", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search titles, transcripts, notes")
        .overlay {
            if groupedMeetings.isEmpty, !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    private var filteredMeetings: [Meeting] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return meetings.map { $0 } }
        // ponytail: linear scan of full transcripts per keystroke; switch to an
        // indexed fetch predicate if libraries ever get huge.
        return meetings.filter { meeting in
            meeting.title.localizedCaseInsensitiveContains(query)
                || meeting.transcriptText.localizedCaseInsensitiveContains(query)
                || meeting.summary?.matches(query) == true
        }
    }

    private var groupedMeetings: [(title: String, items: [Meeting])] {
        var order: [String] = []
        var byTitle: [String: [Meeting]] = [:]
        for meeting in filteredMeetings {
            let title = MeetingDateGroup.title(for: meeting.createdAt)
            if byTitle[title] == nil {
                order.append(title)
            }
            byTitle[title, default: []].append(meeting)
        }
        return order.map { (title: $0, items: byTitle[$0] ?? []) }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        // ScrollView keeps the primary action reachable at accessibility
        // Dynamic Type sizes, where the content exceeds the screen height.
        ScrollView {
            VStack(spacing: 0) {
                emptyStateContent
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 36)
            .padding(.bottom, 28)
        }
    }

    @ViewBuilder private var emptyStateContent: some View {
            ZStack {
                Circle()
                    .fill(LinearGradient.brand)
                    .frame(width: 96, height: 96)
                    .shadow(color: Color.accentColor.opacity(0.35), radius: 18, y: 8)
                Image(systemName: "waveform")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
            .padding(.bottom, 24)

            Text("Capture your first meeting")
                .font(.title2.bold())
                .padding(.bottom, 6)
            Text("Record the room, watch the live transcript, and let on-device intelligence write the notes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
                .padding(.bottom, 28)

            VStack(alignment: .leading, spacing: 16) {
                featureRow("mic.fill", "Record", "High-quality audio with pause and resume")
                featureRow("text.quote", "Transcribe", "Live speech-to-text as the meeting happens")
                featureRow("sparkles", "Summarize", "Key points, decisions, and action items")
                featureRow("lock.fill", "Private", "Stays on this iPhone unless you opt into iCloud Backup")
            }
            .padding(.horizontal, 44)

            recordButton
                .padding(.top, 36)
    }

    private func featureRow(_ systemImage: String, _ title: String, _ caption: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Record button

    private var recordButton: some View {
        Button {
            beginNewMeeting()
        } label: {
            Label("New Meeting", systemImage: "mic.fill")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 30)
                .padding(.vertical, 15)
                .background(LinearGradient.brand, in: Capsule())
                .shadow(color: Color.accentColor.opacity(0.35), radius: 14, y: 6)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityHint("Starts a new recording")
    }

    private func beginNewMeeting() {
        draftTitle = RecordingSession.defaultTitle()
        showingNewMeeting = true
    }

    private func startImport(_ url: URL) {
        importingFileName = url.lastPathComponent
        importTask = Task {
            do {
                let meeting = try await AudioImporter.importAudio(from: url, context: context)
                // Reuses the post-recording destination, so Auto-Summarize
                // kicks in for imports too.
                justFinished = meeting
            } catch is CancellationError {
                // User cancelled — nothing to report.
            } catch {
                importError = error.localizedDescription
            }
            importingFileName = nil
            importTask = nil
        }
    }
}

// MARK: - Row

struct MeetingRowView: View {
    let meeting: Meeting

    var body: some View {
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

            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(meeting.createdAt.formatted(date: .abbreviated, time: .shortened))
                    if meeting.duration > 0 {
                        Text("·")
                        Text(meeting.duration.clockString)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                if meeting.summary != nil {
                    statusChip("Summarized", systemImage: "sparkles", tint: .accentColor)
                } else if meeting.hasTranscript {
                    statusChip("Transcript", systemImage: "text.quote", tint: .secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func statusChip(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

// MARK: - New meeting sheet

struct NewMeetingSheet: View {
    @Binding var title: String
    let onStart: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            // ScrollView keeps Start Recording and the consent notice
            // reachable with the keyboard up or at large Dynamic Type.
            ScrollView {
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(LinearGradient.brand)
                        .frame(width: 68, height: 68)
                        .shadow(color: Color.accentColor.opacity(0.3), radius: 12, y: 5)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .accessibilityHidden(true)
                .padding(.top, 28)
                .padding(.bottom, 18)

                Text("Give it a title you'll recognize later.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 14)

                TextField("Meeting title", text: $title)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .submitLabel(.done)
                    .padding(13)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 22)
                    .accessibilityLabel("Meeting title")

                Button {
                    dismiss()
                    onStart()
                } label: {
                    Label("Start Recording", systemImage: "record.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(
                            LinearGradient(colors: [.red, .red.opacity(0.78)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: Capsule()
                        )
                        .shadow(color: .red.opacity(0.3), radius: 12, y: 5)
                }
                .buttonStyle(PressableButtonStyle())
                .padding(.horizontal, 24)
                .padding(.bottom, 14)

                Label("Recording stays on this iPhone (and your iCloud backup, if enabled). Make sure everyone in the room knows the meeting is being recorded.",
                      systemImage: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 16)
            }
            }
            .navigationTitle("New Meeting")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview {
    MeetingListView()
        .modelContainer(for: Meeting.self, inMemory: true)
}
