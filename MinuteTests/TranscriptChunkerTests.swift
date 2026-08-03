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
        let chunks = TranscriptChunker.chunks(from: text, maxChars: 40, overlapChars: 0)

        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= 40 })
        let recombined = chunks.joined(separator: "\n").split(separator: "\n").map(String.init)
        #expect(recombined == lines)
    }

    @Test func hardSplitsOversizedSingleLine() {
        let text = String(repeating: "a", count: 55)
        let chunks = TranscriptChunker.chunks(from: text, maxChars: 20, overlapChars: 0)

        #expect(chunks.allSatisfy { $0.count <= 20 })
        #expect(chunks.map(\.count).reduce(0, +) == 55)
    }

    @Test func overlapRepeatsTrailingLinesInNextChunk() {
        let lines = (1...10).map { "line number \($0)" }
        let text = lines.joined(separator: "\n")
        let chunks = TranscriptChunker.chunks(from: text, maxChars: 40, overlapChars: 15)

        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= 40 })
        for index in 1..<chunks.count {
            let previousLines = chunks[index - 1].split(separator: "\n")
            let firstLine = chunks[index].split(separator: "\n").first
            #expect(previousLines.last == firstLine)
        }
        // Every original line survives, in order, despite the repeats.
        var remaining = lines[...]
        for line in chunks.joined(separator: "\n").split(separator: "\n").map(String.init) {
            if line == remaining.first {
                remaining = remaining.dropFirst()
            }
        }
        #expect(remaining.isEmpty)
    }

    @Test func overlapNeverPushesChunksOverBudget() {
        // Long lines close to the budget leave no room for carried lines;
        // the chunker must shed the overlap rather than exceed maxChars.
        let lines = (1...6).map { String(repeating: "x\($0)", count: 8) }
        let chunks = TranscriptChunker.chunks(from: lines.joined(separator: "\n"), maxChars: 20, overlapChars: 10)

        #expect(chunks.allSatisfy { $0.count <= 20 })
    }

    @Test func overlapCarriesSuffixOfOversizedTrailingLine() {
        // One speaker talking for a long stretch: the chunk's trailing line
        // exceeds the whole overlap budget, but its suffix must still carry
        // forward instead of dropping the overlap entirely.
        let longTurn = (1...15).map { "word\($0)" }.joined(separator: " ")
        let text = "intro line\n" + longTurn + "\nclosing line of the meeting"
        let chunks = TranscriptChunker.chunks(from: text, maxChars: 120, overlapChars: 30)

        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= 120 })
        // The second chunk starts with a suffix of the long turn, not cold.
        let secondFirstLine = chunks[1].split(separator: "\n").first.map(String.init) ?? ""
        #expect(!secondFirstLine.isEmpty)
        #expect(longTurn.hasSuffix(secondFirstLine))
    }

    @Test func defaultOverlapStaysWithinBudget() {
        let text = (1...400).map { "segment \($0) with some spoken words in it" }.joined(separator: "\n")
        let chunks = TranscriptChunker.chunks(from: text)

        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= TranscriptChunker.defaultMaxChars })
    }
}
