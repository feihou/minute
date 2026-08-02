import SwiftData
import SwiftUI

/// Full-screen recording UI: title, elapsed time, level meter, live transcript,
/// and pause/resume/stop controls.
struct RecordingView: View {
    @Environment(\.modelContext) private var context
    @Bindable var session: RecordingSession
    let onFinish: (Meeting?) -> Void

    @State private var confirmingDiscard = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                TextField("Meeting title", text: $session.title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .accessibilityLabel("Meeting title")

                statusHeader

                ProgressView(value: Double(session.recorder.level))
                    .progressViewStyle(.linear)
                    .tint(.red)
                    .padding(.horizontal, 40)
                    .accessibilityLabel("Microphone level")

                transcriptArea
                    .frame(maxHeight: .infinity)

                controls
                    .padding(.bottom, 24)
            }
            .padding(.top)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Disabled while saving: discarding mid-save races the
                    // finish that's finalizing the transcript.
                    Button("Discard") { confirmingDiscard = true }
                        .tint(.red)
                        .disabled(session.phase == .saving)
                }
            }
            .confirmationDialog(
                "Discard this recording?",
                isPresented: $confirmingDiscard,
                titleVisibility: .visible
            ) {
                Button("Discard Recording", role: .destructive) {
                    Task {
                        await session.discard()
                        onFinish(nil)
                    }
                }
                Button("Keep Recording", role: .cancel) {}
            } message: {
                Text("The audio and transcript so far will be deleted from this iPhone.")
            }
        }
        .interactiveDismissDisabled()
        .task { await session.start() }
    }

    // MARK: - Pieces

    @ViewBuilder private var statusHeader: some View {
        switch session.phase {
        case .preparing:
            ProgressView("Preparing…")
        case .saving:
            ProgressView("Finishing transcript…")
        case .failed(let message):
            VStack(spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    if session.didStartRecording {
                        // Never force the user to throw away captured audio.
                        Button("Save Recording") {
                            Task {
                                // nil = save failed; the session stays in
                                // .failed so this screen remains for a retry.
                                if let meeting = await session.finish(in: context) {
                                    onFinish(meeting)
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button(session.didStartRecording ? "Discard" : "Close", role: .destructive) {
                        Task {
                            await session.discard()
                            onFinish(nil)
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal)
        default:
            HStack(spacing: 10) {
                Circle()
                    .fill(session.phase == .recording ? Color.red : Color.orange)
                    .frame(width: 12, height: 12)
                Text(session.phase == .recording ? "Recording" : "Paused")
                    .font(.headline)
                    .foregroundStyle(session.phase == .recording ? Color.red : Color.orange)
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    Text(session.recorder.elapsed.clockString)
                        .font(.title2.monospacedDigit().weight(.medium))
                }
            }
            .accessibilityElement(children: .combine)
            if let notice = session.notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
    }

    @ViewBuilder private var transcriptArea: some View {
        switch session.transcription.availability {
        case .downloadingModel:
            VStack(spacing: 8) {
                ProgressView("Downloading transcription model…")
                Text("Recording continues while the model downloads — the live transcript starts once it's ready. This only happens once.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        case .unavailable(let reason):
            VStack(spacing: 8) {
                Image(systemName: "text.bubble")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        default:
            liveTranscript
        }
    }

    private var liveTranscript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if session.transcription.segments.isEmpty, session.transcription.volatileText.isEmpty {
                        Text(session.phase == .recording ? "Listening…" : "The live transcript will appear here.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(session.transcription.segments.enumerated()), id: \.offset) { _, segment in
                        Text(segment.text)
                    }
                    if !session.transcription.volatileText.isEmpty {
                        Text(session.transcription.volatileText)
                            .foregroundStyle(.secondary)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("transcript-bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            }
            .onChange(of: session.transcription.segments.count) {
                withAnimation { proxy.scrollTo("transcript-bottom", anchor: .bottom) }
            }
            .onChange(of: session.transcription.volatileText) {
                proxy.scrollTo("transcript-bottom", anchor: .bottom)
            }
        }
    }

    @ViewBuilder private var controls: some View {
        let isActive = session.phase == .recording || session.phase == .paused
        HStack(spacing: 56) {
            Button {
                if session.phase == .recording {
                    session.pause()
                } else {
                    session.resume()
                }
            } label: {
                Image(systemName: session.phase == .recording ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.primary)
            }
            .disabled(!isActive)
            .accessibilityLabel(session.phase == .recording ? "Pause recording" : "Resume recording")

            Button {
                Task {
                    // nil = save failed; the session enters .failed and this
                    // screen shows Save Recording / Discard instead of closing.
                    if let meeting = await session.finish(in: context) {
                        onFinish(meeting)
                    }
                }
            } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.red)
            }
            .disabled(!isActive)
            .accessibilityLabel("Stop and save recording")
        }
    }
}
