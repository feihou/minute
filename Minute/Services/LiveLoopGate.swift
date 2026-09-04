import Foundation

/// A one-way latch the live transcription loop opens when it stops, and that
/// whoever is finalizing the transcript waits on.
///
/// Awaiting the loop's `Task` directly is what this replaces. WhisperKit's
/// model load and decode are cooperative and not preemptible mid-stage, so an
/// in-flight pass can run for minutes after the recording ended — and
/// `RecordingSession.saveWithoutTranscript()` exists precisely to escape that
/// wait. It can only do so if something other than the loop finishing is able
/// to release the finisher, which is what `open()` is: it lets go of the
/// waiter now and leaves the orphaned pass to notice its cancellation and
/// unwind in its own time.
///
/// One-way on purpose. A live session runs once, so there is nothing to reset,
/// and a gate that could close again could strand a finisher that arrived a
/// moment late.
@MainActor
final class LiveLoopGate {
    private(set) var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Returns once the gate is open — immediately if it already is.
    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
        }
    }

    /// Lets go of everyone waiting, and of everyone who asks later. Idempotent:
    /// `cancel()` and the loop's own exit both call this, in either order, and
    /// resuming one continuation twice would trap the process.
    func open() {
        guard !isOpen else { return }
        isOpen = true
        // Emptied before anything is resumed: a resumed waiter can run before
        // this method returns, and must never find its own continuation still
        // listed for a second resume.
        let resuming = waiting
        waiting.removeAll()
        for continuation in resuming {
            continuation.resume()
        }
    }
}
