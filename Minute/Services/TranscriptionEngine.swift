import AVFoundation
import Foundation

/// How ready an engine is to transcribe. Shared by every engine so callers
/// switch on one type regardless of which model the user selected.
enum TranscriptionAvailability: Equatable {
    case unknown
    case available
    case downloadingModel
    case unavailable(String)
}

/// Thrown by the file path when the engine can't run, carrying the same
/// explanation `availability` shows the live path. Re-transcribe and import
/// render `localizedDescription` verbatim, so a bare framework error there
/// would hide the one sentence that tells the user what to do.
struct TranscriptionUnavailableError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// The transcription contract the recording, import, and re-transcribe paths
/// talk to, instead of a concrete engine. Live sessions stream buffers in and
/// observable text out; the file path transcribes in one throwing call.
@MainActor
protocol TranscriptionEngine: AnyObject {
    var availability: TranscriptionAvailability { get }

    /// In-progress (not yet finalized) text for the live transcript view.
    var volatileText: String { get }
    /// Finalized transcript segments in audio order.
    var segments: [TranscriptSegment] { get }
    /// Seconds of audio already recorded before the first buffer reached the
    /// engine (it can attach late); added to every live segment timestamp so
    /// transcript taps seek the right spot. Set before buffers flow.
    var timestampOffset: TimeInterval { get set }

    /// Checks device/model support and loads (or downloads) what's needed.
    func prepare() async

    /// Starts a live session and returns the closure the recorder calls with
    /// each audio buffer, or nil when transcription can't run (never throws —
    /// the recording must not depend on it).
    func start(inputFormat: AVAudioFormat) async -> (@Sendable (AVAudioPCMBuffer) -> Void)?

    /// Flushes remaining audio, waits for final results, and returns them.
    func finish() async -> [TranscriptSegment]

    /// Abandons the live session without waiting for results.
    func cancel() async

    /// Transcribes a whole audio file. ANY failure throws — callers replacing
    /// an existing transcript must never mistake a partial result for a
    /// complete one.
    func transcribe(file: AVAudioFile) async throws -> [TranscriptSegment]
}

/// Picks the engine the user selected in Settings.
@MainActor
enum TranscriptionEngines {
    static func current() -> any TranscriptionEngine {
        switch AppSettings.transcriptionEngine {
        case .appleSpeech: TranscriptionService()
        case .whisper: WhisperTranscriptionService()
        }
    }
}
