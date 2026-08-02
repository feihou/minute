import Testing
@testable import Minute

struct SummaryContextTests {
    @Test func blankContextProducesNoBlock() {
        #expect(SummarizationService.contextBlock(from: "") == nil)
        #expect(SummarizationService.contextBlock(from: "   \n  ") == nil)
    }

    @Test func contextIsFencedAndLabeledAsBackground() throws {
        let block = try #require(SummarizationService.contextBlock(from: "Attendees: Fei, Maria. Project: Minute."))
        #expect(block.contains("<user_context>"))
        #expect(block.contains("Attendees: Fei, Maria. Project: Minute."))
        #expect(block.contains("not part of the meeting"))
    }

    @Test func longContextIsClamped() throws {
        let block = try #require(SummarizationService.contextBlock(from: String(repeating: "x", count: 2_000)))
        #expect(block.count < 700)
    }
}
