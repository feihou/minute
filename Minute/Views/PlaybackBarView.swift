import SwiftUI

/// Play/pause, scrubber, and time labels for a meeting recording. Carries its
/// own surface: on a reading surface it is the one true control in a column of
/// text, so it needs to look tappable without a card around the whole page.
struct PlaybackBarView: View {
    let player: AudioPlayerController
    let url: URL

    @State private var loadError: String?
    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0

    private var displayTime: TimeInterval { isScrubbing ? scrubTime : player.currentTime }

    var body: some View {
        if let loadError {
            Text(loadError)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    Button {
                        player.togglePlayback()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(Color.accentColor, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(player.isPlaying ? "Pause playback" : "Play recording")

                    VStack(spacing: 2) {
                        Slider(
                            value: Binding(
                                get: { displayTime },
                                set: { scrubTime = $0 }
                            ),
                            in: 0...max(player.duration, 0.01)
                        ) { editing in
                            if editing {
                                scrubTime = player.currentTime
                                isScrubbing = true
                            } else {
                                player.seek(to: scrubTime)
                                isScrubbing = false
                            }
                        }
                        .accessibilityLabel("Playback position")

                        // Elapsed and remaining sit at the ends of the track they
                        // describe, the way a player's timeline reads.
                        HStack {
                            Text(displayTime.clockString)
                            Spacer()
                            Text(player.duration.clockString)
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                // One line, under the control that failed: a tap that produced
                // nothing has to say something, or the user taps again.
                if let lastError = player.lastError {
                    Text(lastError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .task(id: url) {
                // List rows re-run .task when scrolled back on screen; don't
                // reload (and reset) an already-loaded player.
                guard !player.isLoaded else { return }
                do {
                    try player.load(url: url)
                } catch {
                    loadError = "This recording can't be played back."
                }
            }
        }
    }
}
