import SwiftData
import SwiftUI

/// Full-screen recording studio: title, status, elapsed time, live waveform,
/// live transcript, and pause/resume/stop controls on a dark backdrop.
struct RecordingView: View {
    @Environment(\.modelContext) private var context
    @Bindable var session: RecordingSession
    let onFinish: (Meeting?) -> Void

    @State private var confirmingDiscard = false
    @State private var levels: [Float] = Array(repeating: 0, count: 42)

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient.studioBackdrop
                    .ignoresSafeArea()

                VStack(spacing: 18) {
                    TextField("Meeting title", text: $session.title)
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                        .accessibilityLabel("Meeting title")

                    statusHeader

                    waveform

                    transcriptCard
                        .frame(maxHeight: .infinity)

                    controls
                        .padding(.bottom, 18)
                }
                .padding(.top)
            }
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
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
        .task { await session.start() }
        .task {
            // Feed the waveform: sample the smoothed mic level ~12×/sec.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                levels.removeFirst()
                levels.append(session.recorder.level)
            }
        }
    }

    // MARK: - Status

    @ViewBuilder private var statusHeader: some View {
        switch session.phase {
        case .preparing:
            ProgressView("Preparing…")
                .padding(.vertical, 20)
        case .saving:
            ProgressView("Finishing transcript…")
                .padding(.vertical, 20)
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
            let isRecording = session.phase == .recording
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(isRecording ? Color.red : Color.orange)
                        .frame(width: 9, height: 9)
                    Text(isRecording ? "Recording" : "Paused")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isRecording ? Color.red : Color.orange)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(.white.opacity(0.08), in: Capsule())

                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    Text(session.recorder.elapsed.clockString)
                        .font(.system(size: 54, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
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

    // MARK: - Waveform

    private var waveform: some View {
        HStack(alignment: .center, spacing: 3.5) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .fill(.white.opacity(session.phase == .recording ? 0.85 : 0.3))
                    .frame(width: 3, height: 6 + CGFloat(levels[index]) * 54)
            }
        }
        .frame(height: 64)
        .animation(.linear(duration: 0.08), value: levels)
        .accessibilityLabel("Microphone level")
        .accessibilityValue("\(Int(session.recorder.level * 100)) percent")
        .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: - Transcript

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Live Transcript", systemImage: "text.quote")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.55))
            transcriptArea
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(16)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal)
    }

    @ViewBuilder private var transcriptArea: some View {
        if !session.isTranscriptionEnabled {
            VStack(spacing: 8) {
                Image(systemName: "waveform.slash")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Live transcription is turned off. The audio is still being recorded — turn transcription on in Settings for future meetings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch session.transcription.availability {
            case .downloadingModel:
                VStack(spacing: 8) {
                    ProgressView("Downloading transcription model…")
                    Text("Recording continues while the model downloads — the live transcript starts once it's ready. This only happens once.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                liveTranscript
            }
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
                            .foregroundStyle(.white.opacity(0.92))
                    }
                    if !session.transcription.volatileText.isEmpty {
                        Text(session.transcription.volatileText)
                            .foregroundStyle(.secondary)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("transcript-bottom")
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: session.transcription.segments.count) {
                withAnimation { proxy.scrollTo("transcript-bottom", anchor: .bottom) }
            }
            .onChange(of: session.transcription.volatileText) {
                proxy.scrollTo("transcript-bottom", anchor: .bottom)
            }
        }
    }

    // MARK: - Controls

    @ViewBuilder private var controls: some View {
        let isActive = session.phase == .recording || session.phase == .paused
        HStack(spacing: 52) {
            VStack(spacing: 6) {
                Button {
                    if session.phase == .recording {
                        session.pause()
                    } else {
                        session.resume()
                    }
                } label: {
                    Image(systemName: session.phase == .recording ? "pause.fill" : "play.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(!isActive)
                .accessibilityLabel(session.phase == .recording ? "Pause recording" : "Resume recording")
                Text(session.phase == .recording ? "Pause" : "Resume")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }

            VStack(spacing: 6) {
                Button {
                    Task {
                        // nil = save failed; the session enters .failed and this
                        // screen shows Save Recording / Discard instead of closing.
                        if let meeting = await session.finish(in: context) {
                            onFinish(meeting)
                        }
                    }
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 78, height: 78)
                        .background(
                            LinearGradient(colors: [.red, .red.opacity(0.75)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: Circle()
                        )
                        .shadow(color: .red.opacity(0.4), radius: 14, y: 6)
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(!isActive)
                .accessibilityLabel("Stop and save recording")
                Text("Stop & Save")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .opacity(isActive ? 1 : 0.4)
    }
}
