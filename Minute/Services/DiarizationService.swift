import FluidAudio
import Foundation
import OSLog

enum DiarizationError: LocalizedError {
    case modelUnavailable
    case processingFailed

    var errorDescription: String? {
        switch self {
        case .modelUnavailable:
            return "The speaker model couldn't be downloaded. Check your connection and try again — identification itself runs entirely on device."
        case .processingFailed:
            return "This recording couldn't be analyzed for speakers."
        }
    }
}

/// On-device speaker diarization over a meeting's saved audio file, built on
/// FluidAudio's offline pipeline. The CoreML models (~22 MB) download once
/// from Hugging Face and are cached; the audio itself never leaves the device.
struct DiarizationService {
    private static let logger = Logger(subsystem: "com.minuteapp.Minute", category: "Diarization")

    /// Returns who spoke when, as engine-agnostic ranges for SpeakerAssignment.
    /// Speaker ids are renumbered later by first appearance, so the raw
    /// indices here only need to be distinct.
    func diarize(
        audioAt url: URL,
        onProgress: (@MainActor @Sendable (String) -> Void)? = nil
    ) async throws -> [SpeakerRange] {
        let manager = OfflineDiarizerManager()

        do {
            await onProgress?("Getting the speaker model…")
            try await manager.prepareModels()
        } catch {
            Self.logger.error("Diarizer model preparation failed: \(error.localizedDescription)")
            throw DiarizationError.modelUnavailable
        }

        // A cancelled job must be discarded rather than applied: MeetingJobs
        // stays silent for a CancellationError and turns anything else into a
        // message. Checked outside the catch above so a Stop tapped during the
        // download is never reported as "the speaker model couldn't be
        // downloaded".
        try Task.checkCancellation()

        await onProgress?("Identifying speakers on device…")
        let result: DiarizationResult
        do {
            result = try await manager.process(url) { done, total in
                guard total > 0 else { return }
                let percent = Int(Double(done) / Double(total) * 100)
                Task { @MainActor in
                    onProgress?("Identifying speakers on device… \(percent)%")
                }
            }
        } catch {
            Self.logger.error("Diarization failed: \(error.localizedDescription)")
            throw DiarizationError.processingFailed
        }

        // Same again after the long pass: applying speaker ranges to a meeting
        // the user stopped working on would renumber its transcript behind them.
        try Task.checkCancellation()

        var indices: [String: Int] = [:]
        return result.segments.map { segment in
            let index = indices[segment.speakerId] ?? {
                let next = indices.count
                indices[segment.speakerId] = next
                return next
            }()
            return SpeakerRange(
                speaker: index,
                start: TimeInterval(segment.startTimeSeconds),
                end: TimeInterval(segment.endTimeSeconds)
            )
        }
    }
}
