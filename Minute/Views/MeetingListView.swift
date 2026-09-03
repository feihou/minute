import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The SwiftUI identity of the detail view this list pushes.
enum MeetingDetailIdentity {
    /// The meeting's identifier while it exists, nil once it is gone.
    ///
    /// The destination closure re-runs on every list update, and the meeting
    /// it was handed can be deleted by then — the Brain tab pushes a detail of
    /// its own from a fact's source link, and deleting there invalidates this
    /// list's query without clearing this stack's destination. `id` still
    /// answers on a deleted meeting, but with a stale value that would key the
    /// detail to a meeting that no longer exists, so the key goes to nil and
    /// the detail's own deleted branch draws the placeholder instead.
    static func key(for meeting: Meeting) -> UUID? {
        meeting.isGone ? nil : meeting.id
    }
}

struct MeetingListView: View {
    var storeIsEphemeral = false

    @Environment(\.modelContext) private var context
    @Environment(KnowledgeCatchUp.self) private var catchUp
    @Environment(MeetingJobs.self) private var jobs
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Meeting.createdAt, order: .reverse) private var meetings: [Meeting]

    @State private var searchText = ""
    @State private var draftTitle = ""
    @State private var draftDefaultTitle = ""
    @State private var showingNewMeeting = false
    @State private var showingSettings = false
    @State private var activeSession: RecordingSession?
    @State private var meetingDestination: Meeting?
    /// Whether the meeting being opened should start summarizing on sight.
    /// Only a just-finished recording does — opening an old meeting from the
    /// Home Screen widget must never kick off work the user didn't ask for.
    @State private var destinationAutoSummarizes = false
    @State private var deleteFailed = false
    /// The meeting a swipe or context menu asked to delete, held until the
    /// confirmation is answered.
    @State private var pendingDelete: Meeting?
    @State private var didSweepOrphans = false
    @State private var showingImporter = false
    @State private var importingFileName: String?
    @State private var importTask: Task<Void, Never>?
    @State private var importError: String?
    /// Why an otherwise-successful import came back without a transcript.
    @State private var transcriptionNote: String?
    @State private var deepLinkState = MeetingDeepLinkState()
    /// The pending widget publish, cancelled and replaced by each new
    /// snapshot so a burst of changes produces one write.
    @State private var widgetPublishTask: Task<Void, Never>?

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
            .alert("Imported Without a Transcript", isPresented: Binding(
                get: { transcriptionNote != nil },
                set: { if !$0 { transcriptionNote = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(transcriptionNote ?? "")
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
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .rect(cornerRadius: 16))
                    .padding(.horizontal)
                }
            }
            .navigationDestination(item: $meetingDestination) { meeting in
                // Keyed so replacing the destination in place (a widget link
                // while a detail is up, a recording finishing under one)
                // builds a fresh view instead of reusing the old one's player,
                // tab, and auto-summary state for a different meeting.
                MeetingDetailView(meeting: meeting, autoGenerateSummary: destinationAutoSummarizes)
                    .id(MeetingDetailIdentity.key(for: meeting))
            }
            // safeAreaBar, not safeAreaInset: the bar reserves its own space and
            // participates in the scroll edge effect, so rows fade out beneath
            // the button instead of colliding with it mid-scroll.
            .safeAreaBar(edge: .bottom) {
                if !meetings.isEmpty {
                    recordButton
                        .padding(.bottom, 8)
                }
            }
        }
        .task {
            // Clean up audio left behind by a crash mid-recording — but never
            // while running on the fallback store, where meetings that
            // reference these files may still exist in the real database.
            guard !storeIsEphemeral, !didSweepOrphans else { return }
            didSweepOrphans = true
            // Its own fetch, not the view's @Query: a query whose fetch failed
            // is silently empty, and an empty referenced set would delete
            // every recording in the library.
            if let referenced = MeetingStore.referencedAudioFileNames(context: context) {
                MeetingStore.removeOrphanedAudio(referencedFileNames: referenced)
            }
            // Same idea for the knowledge base: drops support left by meetings
            // deleted before this existed, and by any earlier pass whose save
            // failed. Runs on the same guard, so it never touches the fallback
            // store, where the meetings backing these facts still exist.
            KnowledgeStore.reconcile(context: context)
        }
        .onChange(of: widgetSnapshot, initial: true) { _, snapshot in
            scheduleWidgetPublish(snapshot)
        }
        .onChange(of: scenePhase) {
            // Leaving the app is the last moment a coalescing window can still
            // finish — the process may be suspended before it expires — and it
            // is also the moment the Home Screen widget is about to be looked
            // at, so publish the current snapshot outright.
            guard scenePhase != .active else { return }
            publishWidgetSnapshotNow()
        }
        .onChange(of: meetings.map(\.id), initial: true) {
            resolvePendingMeetingDeepLink()
        }
        .onOpenURL(perform: handleDeepLink)
        #if DEBUG
        // Screenshot automation: launch arguments stand in for the taps a
        // simulator script can't perform. Debug-only, inert without the flags.
        .onAppear {
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-DemoOpenMeeting") {
                handleDeepLink(MinuteDeepLink.meeting(DemoSeed.heroMeetingID).url)
            }
            if arguments.contains("-DemoOpenRecorder") {
                let session = RecordingSession(title: "Weekly Product Sync")
                // Staging is a hook on the Apple engine only; the screenshot
                // simulator always runs with default settings, so the cast
                // holds there and staging is silently skipped elsewhere.
                (session.transcription as? TranscriptionService)?.stageDemo(
                    segments: [
                        TranscriptSegment(text: "Okay, quick agenda: onboarding metrics, the offline spike, and launch dates.", start: 2, end: 8),
                        TranscriptSegment(text: "Completion in the beta cohort is up eighteen percent since the redesign.", start: 9, end: 15),
                        TranscriptSegment(text: "Support tickets about the permissions step have basically disappeared.", start: 16, end: 21),
                        TranscriptSegment(text: "Nice — then let's get into the offline sync estimate.", start: 22, end: 26),
                        TranscriptSegment(text: "Rough scope is two weeks if we keep conflict resolution simple for v1.", start: 27, end: 32),
                    ],
                    volatileText: "and if the storage layer lands first, we can review it by"
                )
                activeSession = session
            }
            if arguments.contains("-DemoOpenSettings") {
                showingSettings = true
            }
        }
        #endif
        .sheet(isPresented: $showingNewMeeting) {
            NewMeetingSheet(title: $draftTitle) {
                activeSession = RecordingSession(title: draftTitle, prefilledDefaultTitle: draftDefaultTitle)
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .fullScreenCover(item: $activeSession) { session in
            RecordingView(session: session) { finished in
                activeSession = nil
                if let finished {
                    destinationAutoSummarizes = AppSettings.autoSummarizeEnabled
                    meetingDestination = finished
                    nudgeBrain(for: finished)
                }
            }
        }
    }

    // MARK: - List

    private var meetingList: some View {
        List {
            ForEach(groupedMeetings, id: \.title) { group in
                Section {
                    ForEach(group.items) { meeting in
                        NavigationLink {
                            MeetingDetailView(meeting: meeting)
                        } label: {
                            MeetingRowView(meeting: meeting)
                        }
                        .listRowInsets(EdgeInsets(top: 12, leading: Layout.margin, bottom: 12, trailing: Layout.margin))
                        .listRowSeparator(.hidden, edges: .top)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                pendingDelete = meeting
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
                                pendingDelete = meeting
                            } label: {
                                Label("Delete Meeting", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    SectionHeading(group.title)
                        .padding(.top, 10)
                        .padding(.bottom, 2)
                }
                .listRowInsets(EdgeInsets(top: 0, leading: Layout.margin, bottom: 0, trailing: Layout.margin))
            }
        }
        // Plain, not inset-grouped: the day headings already separate the
        // library into blocks, so wrapping every row in its own floating card
        // adds chrome without adding structure.
        .listStyle(.plain)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .searchable(text: $searchText, prompt: "Search titles, transcripts, notes")
        .overlay {
            if groupedMeetings.isEmpty, !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .confirmationDialog(
            "Delete this meeting?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { meeting in
            Button("Delete Meeting", role: .destructive) {
                deleteMeeting(meeting)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(MeetingStore.deleteMeetingWarning)
        }
        .alert("This meeting couldn't be deleted", isPresented: $deleteFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Storage may be full or unavailable. Free up space and try again.")
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
                // Speaker names are shown on every transcript line and in
                // exports, so searching for one should find the meeting even
                // when the name appears nowhere in the transcript text itself.
                || meeting.speakerNames?.contains { $0.localizedCaseInsensitiveContains(query) } == true
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

    private var widgetSnapshot: WidgetSnapshot {
        storeIsEphemeral ? .empty : WidgetSnapshotPublisher.snapshot(from: meetings)
    }

    /// Coalesces publishes into one write per window instead of one per
    /// change. Each new snapshot cancels the pending publish and starts the
    /// window again, so the last value in a burst is the one that lands.
    private func scheduleWidgetPublish(_ snapshot: WidgetSnapshot) {
        widgetPublishTask?.cancel()
        widgetPublishTask = Task {
            try? await Task.sleep(for: WidgetSnapshotPublisher.coalescingWindow)
            guard !Task.isCancelled else { return }
            WidgetSnapshotPublisher.publish(snapshot)
        }
    }

    /// Publishes the current snapshot immediately, dropping any pending
    /// window. `publish` is same-value suppressed, so calling this when
    /// nothing changed costs one comparison and no WidgetKit reload.
    private func publishWidgetSnapshotNow() {
        widgetPublishTask?.cancel()
        widgetPublishTask = nil
        WidgetSnapshotPublisher.publish(widgetSnapshot)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        // ScrollView keeps the primary action reachable at accessibility
        // Dynamic Type sizes, where the content exceeds the screen height.
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                emptyStateContent
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
    }

    @ViewBuilder private var emptyStateContent: some View {
            ZStack {
                Circle()
                    .fill(LinearGradient.brand)
                    .frame(width: 76, height: 76)
                    .shadow(color: Color.accentColor.opacity(0.3), radius: 16, y: 8)
                Image(systemName: "waveform")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
            .padding(.bottom, 26)

            // Left-aligned and set large: the empty screen is the app's cover
            // page, so it gets a headline rather than a centered notice.
            Text("Capture your\nfirst meeting")
                .font(.largeTitle.bold())
                .lineSpacing(2)
                .padding(.bottom, 10)
            Text("Record the room, watch the live transcript, and let on-device intelligence write the notes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.bottom, 34)

            VStack(alignment: .leading, spacing: 18) {
                featureRow("mic.fill", "Record", "High-quality audio with pause and resume")
                featureRow("text.quote", "Transcribe", "Live speech-to-text as the meeting happens")
                featureRow("sparkles", "Summarize", "Key points, decisions, and action items")
                featureRow("lock.fill", "Private", "Stays on this iPhone unless you opt into iCloud backup")
            }

            recordButton
                .padding(.top, 36)
                .frame(maxWidth: .infinity, alignment: .center)
    }

    private func featureRow(_ systemImage: String, _ title: String, _ caption: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
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
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .accessibilityHint("Starts a new recording")
    }

    private func beginNewMeeting() {
        draftDefaultTitle = RecordingSession.defaultTitle()
        draftTitle = draftDefaultTitle
        showingNewMeeting = true
    }

    /// Lets the Brain read a meeting that has just arrived from a recording or
    /// an import. The loop is otherwise only nudged by a finished job or a
    /// scene activation, so with Auto-Summarize off (the default) neither
    /// happens and the meeting goes unread until the app is backgrounded and
    /// reopened.
    ///
    /// Two cases skip the nudge. A meeting with no transcript (a silent save,
    /// an import whose transcription failed) has nothing to read, and the loop
    /// skip-lists it for the rest of the process — spending its one chance, so
    /// the transcript a later Re-transcribe Audio produces would never be
    /// extracted. Nothing is lost by waiting there: that job nudges the loop
    /// itself when it lands. And with Auto-Summarize on, the summary starting
    /// on the next screen already nudges when it finishes
    /// (`MeetingJobs.onContentChanged`), as does the Brain tab's own `.task`;
    /// nudging now would only make extraction and that summary contend for the
    /// single on-device model.
    ///
    /// That second case leans on a fallback: when the selected summary engine
    /// is unavailable, or the summary throws, no completion nudge ever
    /// arrives, and the meeting waits for the Brain tab's own `.task` or the
    /// next scene activation to be read — later than a nudge here, but never
    /// lost.
    private func nudgeBrain(for meeting: Meeting) {
        guard meeting.hasTranscript, !destinationAutoSummarizes else { return }
        catchUp.nudge(context: context)
    }

    private func deleteMeeting(_ meeting: Meeting) {
        // Cleared here, not only through the dialog's isPresented setter:
        // deleting the last meeting swaps `meetingList` — which hosts that
        // dialog — for `emptyState` in the same update, so the setter may
        // never run and this would keep holding a detached Meeting that a
        // later presentation would put back on screen.
        pendingDelete = nil
        // A summary or re-transcription still running on this meeting would
        // keep decoding a deleted file for minutes; stop it first.
        jobs.cancel(meeting)
        deleteFailed = !MeetingStore.delete(meeting, context: context)
    }

    private func handleDeepLink(_ url: URL) {
        guard let deepLink = MinuteDeepLink(url: url) else { return }
        deepLinkState.receive(deepLink)
        switch MeetingDeepLinkState.action(
            for: deepLink,
            isRecording: activeSession != nil,
            isShowingNewMeeting: showingNewMeeting
        ) {
        case .ignore:
            break
        case .presentNewMeeting:
            dismissPresentedSheets()
            beginNewMeeting()
        case .openMeeting:
            dismissPresentedSheets()
            resolvePendingMeetingDeepLink()
        }
    }

    /// Clears anything modal covering the navigation stack, so a deep link's
    /// destination is what the user actually sees. A meeting link used to push
    /// the detail *underneath* an open Settings sheet — the user who tapped a
    /// widget row got Settings until they found Done. Clearing
    /// `showingNewMeeting` here is safe for the new-meeting link too: that
    /// case only reaches this when the sheet is already down.
    private func dismissPresentedSheets() {
        showingSettings = false
        showingImporter = false
        showingNewMeeting = false
    }

    private func resolvePendingMeetingDeepLink() {
        guard let id = deepLinkState.resolve(availableMeetingIDs: meetings.map(\.id)),
              let meeting = meetings.first(where: { $0.id == id }) else { return }
        // Opening an existing meeting from the widget is a request to read it,
        // not to summarize it — a deliberately un-summarized recording must
        // stay that way.
        destinationAutoSummarizes = false
        meetingDestination = meeting
    }

    private func startImport(_ url: URL) {
        importingFileName = url.lastPathComponent
        importTask = Task {
            do {
                let result = try await AudioImporter.importAudio(from: url, context: context)
                transcriptionNote = result.transcriptionNote
                // Reuses the post-recording destination, so Auto-Summarize
                // kicks in for imports too.
                destinationAutoSummarizes = AppSettings.autoSummarizeEnabled
                meetingDestination = result.meeting
                nudgeBrain(for: result.meeting)
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

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Shown only when the meeting still needs something. A badge on every
    /// finished meeting would mark the normal case and carry no information,
    /// so the absence of a note is what says "these notes are ready".
    private var pendingNote: String? {
        guard meeting.summary == nil else { return nil }
        return meeting.hasTranscript ? "No notes yet" : "No transcript"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(meeting.title)
                .font(.headline)
                // Two lines fits nearly every title at normal sizes and keeps
                // the list scannable; at accessibility sizes two lines is a few
                // words, so the title gets the room instead of an ellipsis.
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 5 : 2)
                .foregroundStyle(.primary)

            HStack(spacing: 6) {
                Text(MeetingDateGroup.rowTimestamp(for: meeting.createdAt))
                if meeting.duration > 0 {
                    Text("·")
                    Text(meeting.duration.clockString)
                        .monospacedDigit()
                }
                if let pendingNote {
                    Text("·")
                    Text(pendingNote)
                        .fontWeight(.medium)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
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
                        .frame(width: 64, height: 64)
                        .shadow(color: Color.accentColor.opacity(0.3), radius: 12, y: 5)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .accessibilityHidden(true)
                .padding(.top, 26)
                .padding(.bottom, 18)

                Text("Give it a title you'll recognize later.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 16)

                TextField("Meeting title", text: $title)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .submitLabel(.done)
                    .padding(14)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .accessibilityLabel("Meeting title")

                Button {
                    dismiss()
                    onStart()
                } label: {
                    Label("Start Recording", systemImage: "record.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .tint(.red)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)

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

#if DEBUG
#Preview {
    MeetingListView()
        .modelContainer(MeetingStore.previewContainer())
        .environment(MeetingJobs())
        .environment(KnowledgeCatchUp())
}
#endif
