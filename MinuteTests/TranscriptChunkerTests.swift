import Testing
@testable import Minute

struct TranscriptChunkerTests {
    @Test func emptyTranscriptYieldsNoChunks() {
        #expect(TranscriptChunker.chunks(from: "  \n  ") == [])
    }

    @Test func shortTranscriptIsOneChunk() {
        #expect(TranscriptChunker.chunks(from: "hello world") == ["hello world"])
    }

    @Test func splitsOnLineBoundariesWithoutLosingContent() {
        let lines = (1...10).map { "line number \($0)" }
        let text = lines.joined(separator: "\n")
        let chunks = TranscriptChunker.chunks(from: text, maxChars: 40)

        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= 40 })
        let recombined = chunks.joined(separator: "\n").split(separator: "\n").map(String.init)
        #expect(recombined == lines)
    }

    @Test func hardSplitsOversizedSingleLine() {
        let text = String(repeating: "a", count: 55)
        let chunks = TranscriptChunker.chunks(from: text, maxChars: 20)

        #expect(chunks.allSatisfy { $0.count <= 20 })
        #expect(chunks.map(\.count).reduce(0, +) == 55)
    }
}
