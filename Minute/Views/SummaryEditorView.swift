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
            actionItems: (summary?.actionItems ?? [])
                .map { "\($0.task) | \($0.owner) | \($0.deadline)" }
                .joined(separator: "\n"),
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
            // The "some parts couldn't be summarized" banner describes what the
            // model produced. Once the user has rewritten these notes by hand
            // it is no longer true of what they are reading, and the banner has
            // no other way to go away.
            skippedParts: nil,
            // Not editable here yet; keep whatever the model produced.
            speakerPerspectives: meeting.summary?.speakerPerspectives
        )
        do {
            try context.save()
        } catch {
            // Autosave will retry; nothing actionable for the user here.
        }
    }

    // MARK: - Parsing (unit-tested)

    static func parseList(_ text: String) -> [String] {
        text.split(separator: "\n")
            .map { line in
                var trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("- ") {
                    trimmed = String(trimmed.dropFirst(2))
                }
                return trimmed.trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
    }

    static func parseActionItems(_ text: String) -> [ActionItem] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let task = parts.first, !task.isEmpty else { return nil }
            let owner = parts.count > 1 && !parts[1].isEmpty ? parts[1] : ActionItem.notSpecified
            let deadline = parts.count > 2 && !parts[2].isEmpty ? parts[2] : ActionItem.notSpecified
            return ActionItem(task: task, owner: owner, deadline: deadline)
        }
    }
}
