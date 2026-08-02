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

    /// Copies, transcribes (best effort — an import still succeeds without a
    /// transcript, matching how recording behaves when live transcription
    /// can't run), and saves. Returns the new meeting.
    static func importAudio(
        from sourceURL: URL,
        context: ModelContext,
        transcription: TranscriptionService? = nil
    ) async throws -> Meeting {
        // Built here rather than as a default argument — the class is
        // MainActor-isolated, and default arguments evaluate nonisolated.
        let transcription = transcription ?? TranscriptionService()
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
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        } catch {
            throw ImportError.copyFailed
        }

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
        await transcription.prepare()
        if case .available = transcription.availability {
            segments = (try? await transcription.transcribe(file: audioFile)) ?? []
        }

        // The user may have cancelled while the model worked; don't keep a
        // half-imported meeting behind their back.
        do {
            try Task.checkCancellation()
        } catch {
            MeetingStore.deleteAudioFile(named: fileName)
            throw error
        }

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
        return meeting
    }
}
