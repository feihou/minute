import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import Minute

@MainActor
struct AudioImporterTests {
    /// Half a second of silence, written as a real WAV file.
    private func makeWavFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-fixture-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000)!
        buffer.frameLength = 8_000
        try file.write(from: buffer)
        return url
    }

    /// The container must outlive the context — returning just the context
    /// lets the container deallocate and SwiftData traps on save.
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Meeting.self,
            configurations: MeetingStore.modelConfiguration(inMemory: true)
        )
    }

    @Test func importCreatesMeetingWithAudioAndDuration() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let source = try makeWavFixture()
        defer { try? FileManager.default.removeItem(at: source) }

        let meeting = try await AudioImporter.importAudio(from: source, context: context).meeting

        #expect(meeting.title == source.deletingPathExtension().lastPathComponent)
        #expect(meeting.duration > 0.4 && meeting.duration < 0.6)
        let audioURL = try #require(MeetingStore.audioURL(for: meeting))
        #expect(audioURL.pathExtension == "wav")

        MeetingStore.delete(meeting, context: context)
    }

    @Test func importRejectsNonAudioFileAndLeavesNothingBehind() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-audio-\(UUID().uuidString).wav")
        try Data("this is not audio".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        await #expect(throws: AudioImporter.ImportError.self) {
            _ = try await AudioImporter.importAudio(from: source, context: context)
        }
        let remaining = try context.fetch(FetchDescriptor<Meeting>())
        #expect(remaining.isEmpty)
    }

    /// An engine that is "available" and recognizes nothing — audio in a
    /// language the device isn't set to, or plain silence.
    @MainActor
    private final class EmptyTranscriptionEngine: TranscriptionEngine {
        var availability: TranscriptionAvailability = .available
        var volatileText = ""
        var segments: [TranscriptSegment] = []
        var timestampOffset: TimeInterval = 0
        func prepare() async {}
        func start(inputFormat: AVAudioFormat) async -> (@Sendable (AVAudioPCMBuffer) -> Void)? { nil }
        func finish() async -> [TranscriptSegment] { [] }
        func cancel() async {}
        func transcribe(file: AVAudioFile) async throws -> [TranscriptSegment] { [] }
    }

    @Test func importWithNoRecognizedSpeechExplainsItself() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let source = try makeWavFixture()
        defer { try? FileManager.default.removeItem(at: source) }

        let result = try await AudioImporter.importAudio(
            from: source, context: context, transcription: EmptyTranscriptionEngine()
        )

        // The meeting is kept (the audio is worth having), but the user must
        // hear that nothing was recognized rather than assume the file is silent.
        #expect(result.meeting.segments.isEmpty)
        #expect(result.transcriptionNote == AudioImporter.noSpeechNote)

        MeetingStore.delete(result.meeting, context: context)
    }
}
