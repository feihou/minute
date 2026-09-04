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

    /// The separator carries its spaces, so a bare "|" the model or a user
    /// wrote inside a field is not a delimiter. The two-field line is the
    /// half-typed row people actually produce.
    @Test func splitActionItemLineKeepsBarePipesInsideFields() {
        #expect(SummaryEditorView.splitActionItemLine("A|B | Alice | Friday") == ["A|B", "Alice", "Friday"])
        #expect(SummaryEditorView.splitActionItemLine("a | b") == ["a", "b"])
    }

    /// F52 again: "task | | deadline" is how a row with a deadline but no owner
    /// gets typed, and the two separators there share the single space between
    /// their pipes. Consuming the second one took that shared space with it, so
    /// the first no longer matched " | " — the deadline slid into the owner and
    /// the task kept a dangling "|". The two-space form happened to parse, so
    /// the corruption turned on an invisible character. Same silent field shift
    /// this task exists to remove, and there is no undo.
    @Test func splitActionItemLineReadsAnEmptyOwnerBetweenTwoSeparators() {
        #expect(SummaryEditorView.splitActionItemLine("Ship it | | Friday") == ["Ship it", "", "Friday"])
        #expect(SummaryEditorView.splitActionItemLine("Ship it |  | Friday") == ["Ship it", "", "Friday"])
    }

    @Test func parseActionItemsTreatsAnEmptyOwnerAsNotSpecified() {
        let parsed = SummaryEditorView.parseActionItems("Ship it | | Friday")
        #expect(parsed == [ActionItem(task: "Ship it", owner: "Not specified", deadline: "Friday")])
    }

    /// A whole separator outranks a borrowed space, or an owner that is itself a
    /// bare "|" — which the editor writes as "task | | | deadline" — would come
    /// back as an empty owner and a task carrying the pipe, breaking the round
    /// trip in the very shape the borrowed space was added to read.
    @Test func splitActionItemLinePrefersAWholeSeparatorOverABorrowedSpace() {
        let serialized = SummaryEditorView.serializeActionItems([
            ActionItem(task: "Ship it", owner: "|", deadline: "Friday"),
        ])

        #expect(serialized == "Ship it | | | Friday")
        #expect(SummaryEditorView.splitActionItemLine(serialized) == ["Ship it", "|", "Friday"])
    }

    /// "\r\n" is a single Swift `Character`, so splitting on "\n" never split a
    /// CRLF paste at all: an entire pasted list collapsed into one action item
    /// whose owner and deadline were swallowed by the next row's text.
    @Test func parseActionItemsSplitsCarriageReturnLines() {
        let parsed = SummaryEditorView.parseActionItems("Ship it | Alice | Friday\r\nWrite the doc\rReview it | Priya")
        #expect(parsed == [
            ActionItem(task: "Ship it", owner: "Alice", deadline: "Friday"),
            ActionItem(task: "Write the doc", owner: "Not specified", deadline: "Not specified"),
            ActionItem(task: "Review it", owner: "Priya", deadline: "Not specified"),
        ])
    }

    /// Same bug on every other section of the editor: a CRLF-pasted list of key
    /// points, decisions or section items became a single run-on item.
    @Test func parseListSplitsCarriageReturnLines() {
        #expect(SummaryEditorView.parseList("one\r\ntwo\rthree") == ["one", "two", "three"])
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

    /// The round trip the editor performs on every Save: whatever the editor
    /// serialized must parse back to the identical items, or saving rewrites
    /// notes the user never edited. Built by calling `serializeActionItems` —
    /// the one serializer `init` itself uses — rather than a hand-copied format
    /// literal, so that changing the written format without changing the parser
    /// fails here instead of silently shifting every field a column on the next
    /// Save.
    @Test func actionItemsSurviveTheEditorsSerializeParseRoundTrip() {
        let items = [
            ActionItem(task: "Decide A | B pricing", owner: "Alice", deadline: "Friday"),
            ActionItem(task: "Ship the fix", owner: "Not specified", deadline: "Not specified"),
        ]

        let serialized = SummaryEditorView.serializeActionItems(items)

        // The wire format itself, pinned so a change to it is a decision rather
        // than a side effect — the round trip alone would stay green on any
        // self-consistent format, including one that loses the user's data.
        #expect(serialized == """
            Decide A | B pricing | Alice | Friday
            Ship the fix | Not specified | Not specified
            """)
        #expect(SummaryEditorView.parseActionItems(serialized) == items)
    }

    /// The accepted limit of an unescaped line format a human types by hand: a
    /// separator inside the owner or deadline is indistinguishable from a real
    /// one, so those fields shift. Owners are names and deadlines are dates,
    /// where this is vanishingly rare, and escaping would tax everyone who types
    /// a row. Pinned so the trade-off stays a decision, not a surprise.
    @Test func aSeparatorInsideTheDeadlineStillShiftsFields() {
        let serialized = SummaryEditorView.serializeActionItems([
            ActionItem(task: "Ship it", owner: "Alice", deadline: "Mon | Tue"),
        ])

        #expect(SummaryEditorView.parseActionItems(serialized)
            == [ActionItem(task: "Ship it | Alice", owner: "Mon", deadline: "Tue")])
    }

    /// B12: a row typed left to right and abandoned after the owner —
    /// "Ship it | Alice |" — ends with a separator that opens a field nobody
    /// filled. The backwards search finds the whole separator before it first,
    /// so that empty tail came back attached to the owner: "Alice |" saved as
    /// the person's name, dangling pipe and all, and there is no undo. An empty
    /// trailing field is what "nothing typed there" looks like, so it is
    /// dropped. The trailing-space form is the same line with the separator
    /// fully typed out.
    @Test func splitActionItemLineDropsATrailingEmptyFieldInsteadOfMakingItAnOwner() {
        #expect(SummaryEditorView.splitActionItemLine("Ship it | Alice |") == ["Ship it", "Alice"])
        #expect(SummaryEditorView.splitActionItemLine("Ship it | Alice | ") == ["Ship it", "Alice"])
        #expect(SummaryEditorView.splitActionItemLine("Ship it |") == ["Ship it"])
        // Repeated, or the pipe the first shed leaves behind rides along on the
        // task: "Ship it | |" is two openings, not a task called "Ship it |".
        #expect(SummaryEditorView.splitActionItemLine("Ship it | |") == ["Ship it"])
    }

    @Test func parseActionItemsSavesAnOwnerWithoutTheDanglingPipe() {
        let parsed = SummaryEditorView.parseActionItems("Ship it | Alice |")
        #expect(parsed == [ActionItem(task: "Ship it", owner: "Alice", deadline: "Not specified")])
    }

    /// What dropping a trailing empty field costs, pinned like this file's
    /// other accepted limits: a deadline that is itself a bare "|" serializes
    /// to a line ending in " |", and now reads as a field the user never
    /// filled. Owners are names and deadlines are dates — a lone pipe in one is
    /// not something anyone types, while "Ship it | Alice |" is exactly what
    /// people do type.
    @Test func aTrailingBarePipeDeadlineIsDroppedRatherThanKept() {
        let serialized = SummaryEditorView.serializeActionItems([
            ActionItem(task: "Ship it", owner: "Alice", deadline: "|"),
        ])

        #expect(serialized == "Ship it | Alice | |")
        #expect(SummaryEditorView.parseActionItems(serialized)
            == [ActionItem(task: "Ship it", owner: "Alice", deadline: "Not specified")])
    }
}
