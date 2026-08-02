import SwiftUI

/// Play/pause, scrubber, and time labels for a meeting recording.
struct PlaybackBarView: View {
    let player: AudioPlayerController
    let url: URL

    @State private var loadError: String?
    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0

    var body: some View {
        if let loadError {
            Text(loadError)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 12) {
                Button {
                    player.togglePlayback()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 36))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? "Pause playback" : "Play recording")

                Slider(
                    value: Binding(
                        get: { isScrubbing ? scrubTime : player.currentTime },
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

                Text("\((isScrubbing ? scrubTime : player.currentTime).clockString) / \(player.duration.clockString)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
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
