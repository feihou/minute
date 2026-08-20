import SwiftData
import SwiftUI

/// Full-screen recording studio: title, status, elapsed time, live waveform,
/// live transcript, and pause/resume/stop controls on a dark backdrop.
struct RecordingView: View {
    @Environment(\.modelContext) private var context
    @Bindable var session: RecordingSession
    let onFinish: (Meeting?) -> Void

    @State private var confirmingDiscard = false
    @State private var levels: [Float] = Array(repeating: 0, count: 48)

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient.studioBackdrop
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    TextField("Meeting title", text: $session.title)
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                        .accessibilityLabel("Meeting title")

                    statusHeader
                        .padding(.top, 20)

                    waveform
                        .padding(.top, 26)

                    transcriptCard
                        .frame(maxHeight: .infinity)
                        .padding(.top, 26)

                    controls
                        .padding(.top, 24)
                        .padding(.bottom, 20)
                }
                .padding(.top, 8)
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
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                levels.removeFirst()
                levels.append(currentLevel(tick: tick))
                tick += 1
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
            VStack(spacing: 14) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(isRecording ? Color.red : Color.orange)
                        .frame(width: 8, height: 8)
                    // Sentence case, not .textCase(.uppercase): this VStack
                    // combines its children into one accessibility element, so
                    // an uppercased string here becomes the label VoiceOver
                    // reads and the only name this status has.
                    Text(isRecording ? "Recording" : "Paused")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isRecording ? Color.red : Color.orange)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .glassEffect()

                // The clock is the screen's anchor — everything else is
                // secondary to "how long have I been recording".
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    Text(session.recorder.elapsed.clockString)
                        .font(.system(size: 62, weight: .light, design: .rounded).monospacedDigit())
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
                    .padding(.top, 12)
            }
        }
    }

    // MARK: - Waveform

    private var waveform: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(Color.accentColor.mix(with: .white, by: 0.35))
                    // Older samples fade toward the left, so the trace visibly
                    // flows into "now" on the right instead of sitting static.
                    .opacity(barOpacity(at: index))
                    .frame(width: 3, height: 4 + CGFloat(levels[index]) * 58)
            }
        }
        .frame(height: 66)
        .opacity(session.phase == .recording ? 1 : 0.32)
        .animation(.linear(duration: 0.08), value: levels)
        .accessibilityLabel("Microphone level")
        .accessibilityValue("\(Int(session.recorder.level * 100)) percent")
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// The mic level, except under the screenshot flag — the simulator records
    /// silence, which would draw the waveform as a flat line in App Store
    /// captures. Mirrors the existing `stageDemo` transcript staging.
    private func currentLevel(tick: Int) -> Float {
        #if DEBUG
        if Self.isDemoRecorder {
            // Two detuned sines under a slow envelope: syllable-rate movement
            // that reads as speech, and deterministic, so captures repeat.
            let t = Double(tick)
            let syllables = abs(sin(t * 0.55)) * 0.6 + abs(sin(t * 1.31)) * 0.3
            let breath = 0.55 + 0.45 * sin(t * 0.08)
            return Float(min(1, max(0.05, syllables * breath)))
        }
        #endif
        return session.recorder.level
    }

    #if DEBUG
    private static let isDemoRecorder = ProcessInfo.processInfo.arguments.contains("-DemoOpenRecorder")
    #endif

    private func barOpacity(at index: Int) -> Double {
        guard levels.count > 1 else { return 1 }
        return 0.28 + 0.72 * (Double(index) / Double(levels.count - 1))
    }

    // MARK: - Transcript

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Live Transcript")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.9)
                .foregroundStyle(.white.opacity(0.45))
                .accessibilityLabel("Live Transcript")
            transcriptArea
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(18)
        // A plain translucent fill, not glass: this is content the user is
        // reading, and glass belongs on the floating control layer.
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .padding(.horizontal, Layout.margin)
    }

    @ViewBuilder private var transcriptArea: some View {
        if !session.isTranscriptionEnabled {
            transcriptPlaceholder(
                "waveform.slash",
                "Live transcription is turned off. The audio is still being recorded — turn transcription on in Settings for future meetings."
            )
        } else {
            switch session.transcription.availability {
            case .downloadingModel:
                VStack(spacing: 10) {
                    ProgressView("Downloading transcription model…")
                    Text("Recording continues while the model downloads — the live transcript starts once it's ready. This only happens once.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unavailable(let reason):
                transcriptPlaceholder("text.bubble", reason)
            default:
                liveTranscript
            }
        }
    }

    private func transcriptPlaceholder(_ systemImage: String, _ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.white.opacity(0.35))
            Text(message)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var liveTranscript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if session.transcription.segments.isEmpty, session.transcription.volatileText.isEmpty {
                        Text(session.phase == .recording ? "Listening…" : "The live transcript will appear here.")
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    ForEach(Array(session.transcription.segments.enumerated()), id: \.offset) { _, segment in
                        Text(segment.text)
                            .foregroundStyle(.white.opacity(0.9))
                            .lineSpacing(3)
                    }
                    if !session.transcription.volatileText.isEmpty {
                        // Not yet finalized by the recognizer — dimmed so the
                        // words that may still change are visibly provisional.
                        Text(session.transcription.volatileText)
                            .foregroundStyle(.white.opacity(0.45))
                            .lineSpacing(3)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("transcript-bottom")
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
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
        GlassEffectContainer {
            HStack(spacing: 52) {
                VStack(spacing: 8) {
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
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isActive)
                    .accessibilityLabel(session.phase == .recording ? "Pause recording" : "Resume recording")
                    Text(session.phase == .recording ? "Pause" : "Resume")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                }

                VStack(spacing: 8) {
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
                            .glassEffect(.regular.tint(.red).interactive(), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isActive)
                    .accessibilityLabel("Stop and save recording")
                    Text("Stop & Save")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
        .opacity(isActive ? 1 : 0.4)
    }
}
