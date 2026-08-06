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

/// The file-transcription contract the import, re-transcribe, and
/// after-save paths talk to, instead of a concrete engine. Live streaming
/// during recording remains Apple-only for now — Whisper transcribes the
/// finished file instead.
@MainActor
protocol TranscriptionEngine: AnyObject {
    var availability: TranscriptionAvailability { get }

    /// Checks device/model support and loads (or downloads) what's needed.
    func prepare() async

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
