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

    /// F52: the editor serializes "task | owner | deadline" and used to split
    /// on every "|", so a model-written task containing one shifted every
    /// field a column left — the wrong owner, and the deadline gone. There is
    /// no undo.
    @Test func parseActionItemsKeepsAPipeInsideTheTask() {
        let parsed = SummaryEditorView.parseActionItems("Decide A | B pricing | Alice | Friday")
        #expect(parsed == [ActionItem(task: "Decide A | B pricing", owner: "Alice", deadline: "Friday")])
    }

    @Test func parseActionItemsSplitsOnTheLastTwoSeparatorsOnly() {
        #expect(SummaryEditorView.splitActionItemLine("a | b | c | d") == ["a | b", "c", "d"])
        #expect(SummaryEditorView.splitActionItemLine("only a task") == ["only a task"])
    }

    /// A user-typed line with one separator still means task + owner, as it
    /// did before — the deadline is what's missing, not the owner.
    @Test func parseActionItemsTreatsASingleSeparatorAsTheOwner() {
        let parsed = SummaryEditorView.parseActionItems("Send the deck | Priya")
        #expect(parsed == [ActionItem(task: "Send the deck", owner: "Priya", deadline: "Not specified")])
    }

    @Test func parseActionItemsNormalizesPlaceholderOwnersAndDeadlines() {
        let parsed = SummaryEditorView.parseActionItems("Book the room | none | unknown")
        #expect(parsed == [ActionItem(task: "Book the room", owner: "Not specified", deadline: "Not specified")])
    }

    /// The round trip the editor performs on every Save: whatever `init`
    /// serialized must parse back to the identical items, or saving rewrites
    /// notes the user never edited.
    @Test func actionItemsSurviveTheEditorsSerializeParseRoundTrip() {
        let items = [
            ActionItem(task: "Decide A | B pricing", owner: "Alice", deadline: "Friday"),
            ActionItem(task: "Ship the fix", owner: "Not specified", deadline: "Not specified"),
        ]
        let serialized = items
            .map { "\($0.task) | \($0.owner) | \($0.deadline)" }
            .joined(separator: "\n")

        #expect(SummaryEditorView.parseActionItems(serialized) == items)
    }
}
