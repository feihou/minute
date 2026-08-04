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
}
