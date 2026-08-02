import SwiftData
import SwiftUI

struct MeetingListView: View {
    var storeIsEphemeral = false

    @Environment(\.modelContext) private var context
    @Query(sort: \Meeting.createdAt, order: .reverse) private var meetings: [Meeting]

    @State private var draftTitle = ""
    @State private var showingNewMeeting = false
    @State private var showingSettings = false
    @State private var activeSession: RecordingSession?
    @State private var justFinished: Meeting?
    @State private var didSweepOrphans = false

    var body: some View {
        NavigationStack {
            Group {
                if meetings.isEmpty {
                    ContentUnavailableView {
                        Label("No Meetings", systemImage: "mic")
                    } description: {
                        Text("Record a meeting and Minute will transcribe and summarize it — entirely on this iPhone.")
                    } actions: {
                        Button("New Meeting") { beginNewMeeting() }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(meetings) { meeting in
                            NavigationLink {
                                MeetingDetailView(meeting: meeting)
                            } label: {
                                MeetingRowView(meeting: meeting)
                            }
                        }
                        .onDelete(perform: deleteMeetings)
                    }
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
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        beginNewMeeting()
                    } label: {
                        Label("New Meeting", systemImage: "plus")
                    }
                }
            }
            .navigationDestination(item: $justFinished) { meeting in
                MeetingDetailView(meeting: meeting)
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

    private func beginNewMeeting() {
        draftTitle = RecordingSession.defaultTitle()
        showingNewMeeting = true
    }

    private func deleteMeetings(at offsets: IndexSet) {
        for index in offsets {
            MeetingStore.delete(meetings[index], context: context)
        }
    }
}

struct MeetingRowView: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(meeting.title)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(meeting.createdAt.formatted(date: .abbreviated, time: .shortened))
                if meeting.duration > 0 {
                    Text("·")
                    Text(meeting.duration.clockString)
                }
                if meeting.summary != nil {
                    Text("·")
                    Label("Summarized", systemImage: "sparkles")
                        .labelStyle(.titleOnly)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct NewMeetingSheet: View {
    @Binding var title: String
    let onStart: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Meeting title", text: $title)
                        .submitLabel(.done)
                }
                Section {
                    Button {
                        dismiss()
                        onStart()
                    } label: {
                        Label("Start Recording", systemImage: "record.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowInsets(EdgeInsets())
                } footer: {
                    Text("Minute records with the microphone and keeps everything on this iPhone. Make sure everyone in the room knows the meeting is being recorded.")
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
        .presentationDetents([.medium])
    }
}

#Preview {
    MeetingListView()
        .modelContainer(for: Meeting.self, inMemory: true)
}
