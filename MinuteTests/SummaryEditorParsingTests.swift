import Testing
@testable import Minute

struct SummaryEditorParsingTests {
    @Test func parseListTrimsAndDropsEmptyLines() {
        let parsed = SummaryEditorView.parseList("  first  \n\n second\n   \n")
        #expect(parsed == ["first", "second"])
    }

    @Test func parseListStripsBulletPrefixes() {
        let parsed = SummaryEditorView.parseList("- one\n- two\nthree")
        #expect(parsed == ["one", "two", "three"])
    }

    @Test func parseActionItemsFillsMissingFieldsWithNotSpecified() {
        let parsed = SummaryEditorView.parseActionItems("Do the thing")
        #expect(parsed == [ActionItem(task: "Do the thing", owner: "Not specified", deadline: "Not specified")])
    }

    @Test func parseActionItemsReadsAllThreeFields() {
        let parsed = SummaryEditorView.parseActionItems("Do the thing | Alex | Friday")
        #expect(parsed == [ActionItem(task: "Do the thing", owner: "Alex", deadline: "Friday")])
    }

    @Test func parseActionItemsSkipsLinesWithoutTask() {
        let parsed = SummaryEditorView.parseActionItems(" | Alex | Friday\nReal task")
        #expect(parsed.count == 1)
        #expect(parsed[0].task == "Real task")
    }
}
