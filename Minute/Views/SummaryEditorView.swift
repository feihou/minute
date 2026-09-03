import SwiftData
import SwiftUI

/// Edits the generated summary. Lists are one item per line; action items use
/// "task | owner | deadline" per line.
struct SummaryEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let meeting: Meeting

    /// Everything the editor edits, snapshotted when the sheet opens.
    private struct Draft: Equatable {
        var overview: String
        var keyPoints: String
        var decisions: String
        var actionItems: String
        var openQuestions: String
        /// Items for each template-defined section, positionally matching
        /// `sectionTitles`.
        var sectionTexts: [String]
    }

    @State private var draft: Draft
    /// The snapshot the sheet opened with, so Cancel can tell an untouched
    /// editor from one holding unsaved work.
    @State private var original: Draft
    /// Template-defined section names (titles fixed, items editable); empty
    /// for standard-template summaries. @State, not a plain `let`: a
    /// regeneration landing while the sheet is open rebuilds this view with a
    /// new summary, and a stored property would take the new titles while
    /// `draft.sectionTexts` kept the old count — `ForEach` over the titles
    /// would then subscript past the end of the texts.
    @State private var sectionTitles: [String]
    @State private var confirmingDiscard = false

    init(meeting: Meeting) {
        self.meeting = meeting
        let summary = meeting.summary
        let sections = summary?.sections ?? []
        let draft = Draft(
            overview: summary?.overview ?? "",
            keyPoints: (summary?.keyPoints ?? []).joined(separator: "\n"),
            decisions: (summary?.decisions ?? []).joined(separator: "\n"),
            actionItems: Self.serializeActionItems(summary?.actionItems ?? []),
            openQuestions: (summary?.openQuestions ?? []).joined(separator: "\n"),
            sectionTexts: sections.map { $0.items.joined(separator: "\n") }
        )
        _draft = State(initialValue: draft)
        _original = State(initialValue: draft)
        _sectionTitles = State(initialValue: sections.map(\.title))
    }

    private var hasChanges: Bool { draft != original }

    var body: some View {
        NavigationStack {
            Form {
                Section("Overview") {
                    TextEditor(text: $draft.overview)
                        .frame(minHeight: 80)
                }
                if sectionTitles.isEmpty {
                    Section {
                        TextEditor(text: $draft.keyPoints)
                            .frame(minHeight: 80)
                    } header: {
                        Text("Key Points")
                    } footer: {
                        Text("One item per line.")
                    }
                    Section {
                        TextEditor(text: $draft.decisions)
                            .frame(minHeight: 60)
                    } header: {
                        Text("Decisions")
                    } footer: {
                        Text("One item per line.")
                    }
                } else {
                    // Bounded by the texts as well as the titles so the two can
                    // never disagree, however this view is rebuilt.
                    ForEach(0..<min(sectionTitles.count, draft.sectionTexts.count), id: \.self) { index in
                        Section {
                            TextEditor(text: $draft.sectionTexts[index])
                                .frame(minHeight: 60)
                        } header: {
                            Text(sectionTitles[index])
                        } footer: {
                            Text("One item per line.")
                        }
                    }
                }
                Section {
                    TextEditor(text: $draft.actionItems)
                        .frame(minHeight: 80)
                } header: {
                    Text("Action Items")
                } footer: {
                    Text("One per line, as: task | owner | deadline")
                }
                if sectionTitles.isEmpty {
                    Section {
                        TextEditor(text: $draft.openQuestions)
                            .frame(minHeight: 60)
                    } header: {
                        Text("Open Questions")
                    } footer: {
                        Text("One item per line.")
                    }
                }
            }
            .navigationTitle("Edit Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if hasChanges {
                            confirmingDiscard = true
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                }
            }
            .confirmationDialog(
                "Discard your changes?",
                isPresented: $confirmingDiscard,
                titleVisibility: .visible
            ) {
                Button("Discard Changes", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            }
        }
        // A swipe-down is easy to trigger while scrolling a Form; without this
        // it throws away everything typed with no way back.
        .interactiveDismissDisabled(hasChanges)
    }

    private func save() {
        // An untouched editor must not rewrite the summary. Every field would
        // round-trip through the line parsers, and a list item the model wrote
        // with an embedded newline in it comes back as two items — for a Save
        // the user made no edit to. `original` is exactly what `init`
        // serialized, so this compares the draft against that snapshot.
        guard hasChanges else { return }
        meeting.summary = MeetingSummary(
            overview: draft.overview.trimmingCharacters(in: .whitespacesAndNewlines),
            keyPoints: Self.parseList(draft.keyPoints),
            decisions: Self.parseList(draft.decisions),
            actionItems: Self.parseActionItems(draft.actionItems),
            openQuestions: Self.parseList(draft.openQuestions),
            generatedAt: meeting.summary?.generatedAt ?? .now,
            suggestedTitle: meeting.summary?.suggestedTitle,
            sections: sectionTitles.isEmpty ? nil : zip(sectionTitles, draft.sectionTexts).map {
                SummarySection(title: $0, items: Self.parseList($1))
            },
            // Deliberately preserved. Saving the editor — even after rewriting
            // a section — does not restore the transcript parts the model
            // failed on, and merely opening the editor and tapping Save would
            // otherwise clear the warning without changing anything. Making
            // demonstrably incomplete notes look complete is worse than a
            // banner that only regenerating can retire.
            skippedParts: meeting.summary?.skippedParts,
            // Not editable here yet; keep whatever the model produced.
            speakerPerspectives: meeting.summary?.speakerPerspectives
        )
        do {
            try context.save()
        } catch {
            // Autosave will retry; nothing actionable for the user here.
        }
    }

    // MARK: - Serializing and parsing (unit-tested)

    /// Splits editor text into lines on any newline, not just "\n". A CRLF
    /// pasted in from another app is a single Swift `Character`, so
    /// `split(separator: "\n")` found no break in it and folded a whole pasted
    /// list into one run-on item.
    static func splitLines(_ text: String) -> [Substring] {
        text.split(whereSeparator: \.isNewline)
    }

    static func parseList(_ text: String) -> [String] {
        splitLines(text)
            .map { line in
                var trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("- ") {
                    trimmed = String(trimmed.dropFirst(2))
                }
                return trimmed.trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
    }

    /// The separator written between the three fields. It carries its spaces so
    /// a bare "|" inside a field is not a delimiter.
    static let actionItemSeparator = " | "

    /// The only place the "task | owner | deadline" format is written, so the
    /// editor's serialization and `splitActionItemLine`'s parsing cannot drift
    /// apart. When they did — a literal here, a constant there — changing one
    /// shifted every field a column on the next Save, rewriting notes the user
    /// never edited, with no undo. `init` calls this, and so does the round-trip
    /// test, so there is one definition of the format to disagree with.
    static func serializeActionItems(_ items: [ActionItem]) -> String {
        items
            .map { [$0.task, $0.owner, $0.deadline].joined(separator: actionItemSeparator) }
            .joined(separator: "\n")
    }

    /// Splits one line into at most three fields, on the LAST two separators.
    /// Everything left of them is the task, however many pipes it contains —
    /// splitting on every "|" turned a model-written "Compare vendor A |
    /// vendor B" into a task, an owner and a deadline that all belonged to the
    /// task, silently and with no undo. A line with a single separator still
    /// means task + owner, which is what a user typing one row expects.
    static func splitActionItemLine(_ line: String) -> [String] {
        var fields: [String] = []
        var head = Substring(line)
        while fields.count < 2, let range = head.range(of: actionItemSeparator, options: .backwards) {
            fields.insert(String(head[range.upperBound...]), at: 0)
            head = head[..<range.lowerBound]
        }
        fields.insert(String(head), at: 0)
        return fields
    }

    static func parseActionItems(_ text: String) -> [ActionItem] {
        splitLines(text).compactMap { line in
            // Trimmed the same way `normalizedField` trims the other two
            // fields, so one line cannot yield a task carrying whitespace the
            // owner and deadline had stripped.
            let fields = splitActionItemLine(String(line))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard let task = fields.first, !task.isEmpty else { return nil }
            // Same normalization generated summaries get, so a hand-typed
            // "none" reads as the placeholder everywhere instead of appearing
            // as an owner named none.
            return ActionItem(
                task: task,
                owner: SummarizationService.normalizedField(fields.count > 1 ? fields[1] : ""),
                deadline: SummarizationService.normalizedField(fields.count > 2 ? fields[2] : "")
            )
        }
    }
}
