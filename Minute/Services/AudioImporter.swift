import AVFoundation
import Foundation
import SwiftData

/// Imports an existing audio file: copies it into the recordings directory,
/// transcribes it on device when possible, and saves a Meeting. Everything
/// stays local, matching the recording path.
@MainActor
enum AudioImporter {
    enum ImportError: LocalizedError {
        case unreadable
        case copyFailed
        case saveFailed

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return "This file couldn't be read as audio."
            case .copyFailed:
                return "The audio couldn't be copied into the app's storage. Free up space and try again."
            case .saveFailed:
                return "The meeting couldn't be saved — storage may be full."
            }
        }
    }

    /// A finished import. The note explains why the meeting arrived without a
    /// transcript, so a silently text-less import can say what went wrong
    /// instead of looking like the recording simply had no speech.
    struct Result {
        let meeting: Meeting
        let transcriptionNote: String?
    }

    /// Shown when the engine ran and recognized nothing: the meeting is still
    /// saved, but "no transcript" must not read as "no speech".
    static let noSpeechNote = "The audio was imported, but no speech was recognized in it. If the recording is in another language, check the iPhone's language or the transcription engine in Settings, then use Re-transcribe Audio."

    /// Copies, transcribes (best effort — an import still succeeds without a
    /// transcript, matching how recording behaves when live transcription
    /// can't run), and saves.
    ///
    /// `transcription` is injectable for tests; it defaults to nil rather than
    /// to `TranscriptionEngines.current()` because a default argument is
    /// evaluated outside this type's main-actor isolation.
    static func importAudio(
        from sourceURL: URL,
        context: ModelContext,
        transcription: (any TranscriptionEngine)? = nil
    ) async throws -> Result {
        let transcription = transcription ?? TranscriptionEngines.current()
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let fileName = MeetingStore.importedAudioFileName(originalExtension: sourceURL.pathExtension)
        let destination: URL
        do {
            destination = try MeetingStore.audioURL(fileName: fileName)
            // Copying happens off the main actor: large files (or files a
            // provider must download first) would otherwise freeze the UI
            // and make the Cancel button untappable.
            try await Self.copyFile(from: sourceURL, to: destination)
        } catch {
            // A failed copy can leave a partial file behind; never let it
            // linger invisibly in Recordings.
            MeetingStore.deleteAudioFile(named: fileName)
            throw ImportError.copyFailed
        }

        // The synchronous copy can't observe cancellation itself — honor a
        // Cancel tapped during it before any further expensive work.
        try Self.checkCancellation(cleaningUp: fileName)

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: destination)
        } catch {
            MeetingStore.deleteAudioFile(named: fileName)
            throw ImportError.unreadable
        }
        let sampleRate = audioFile.fileFormat.sampleRate
        let duration = sampleRate > 0 ? Double(audioFile.length) / sampleRate : 0

        var segments: [TranscriptSegment] = []
        var transcriptionNote: String?
        await transcription.prepare()
        switch transcription.availability {
        case .available:
            do {
                segments = try await transcription.transcribe(file: audioFile)
                if segments.isEmpty {
                    transcriptionNote = Self.noSpeechNote
                }
            } catch is CancellationError {
                // Cancelling leaves the already-copied recording in the
                // Recordings directory with no Meeting referencing it. Every
                // other cancellation path here cleans up before rethrowing;
                // this one has to as well, or the user's audio sits on disk
                // invisibly until some later launch happens to sweep orphans.
                MeetingStore.deleteAudioFile(named: fileName)
                throw CancellationError()
            } catch {
                // The import still succeeds — the audio is worth keeping — but
                // swallowing this left the user staring at a transcript-less
                // meeting with no idea whether the file was silent or the
                // model had failed.
                transcriptionNote = "The audio was imported, but transcribing it failed: \(error.localizedDescription)"
            }
        case .unavailable(let message):
            transcriptionNote = "The audio was imported without a transcript. \(message)"
        case .unknown, .downloadingModel, .loadingModel:
            transcriptionNote = "The audio was imported without a transcript because the speech model wasn't ready."
        }

        // The user may have cancelled while the model worked; don't keep a
        // half-imported meeting behind their back.
        try Self.checkCancellation(cleaningUp: fileName)

        let meeting = Meeting(
            title: sourceURL.deletingPathExtension().lastPathComponent,
            duration: duration.isFinite ? duration : 0,
            audioFileName: fileName,
            segments: segments
        )
        context.insert(meeting)
        do {
            try context.save()
        } catch {
            context.delete(meeting)
            MeetingStore.deleteAudioFile(named: fileName)
            throw ImportError.saveFailed
        }
        return Result(meeting: meeting, transcriptionNote: transcriptionNote)
    }

    /// Runs off the main actor (nonisolated async), keeping the UI live
    /// while large files copy.
    ///
    /// Coordinated, because the common source is iCloud Drive: a file that has
    /// been offloaded is only a placeholder on disk, and a bare `copyItem`
    /// fails instantly with "no such file" — which the caller then reports as
    /// "storage may be full", sending the user off to delete photos for a
    /// problem that was never about space. The coordinator materializes the
    /// file first and hands back a readable URL.
    private nonisolated static func copyFile(from source: URL, to destination: URL) async throws {
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
            do {
                try FileManager.default.copyItem(at: readable, to: destination)
            } catch {
                copyError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
    }

    /// Rethrows cancellation after removing the partially imported audio,
    /// so a cancelled import never leaves files behind.
    private static func checkCancellation(cleaningUp fileName: String) throws {
        do {
            try Task.checkCancellation()
        } catch {
            MeetingStore.deleteAudioFile(named: fileName)
            throw error
        }
    }
}
