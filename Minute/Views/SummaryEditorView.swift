import SwiftData
import SwiftUI

/// Edits the generated summary. Lists are one item per line; action items use
/// "task | owner | deadline" per line.
struct SummaryEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let meeting: Meeting

    @State private var overview: String
    @State private var keyPoints: String
    @State private var decisions: String
    @State private var actionItems: String
    @State private var openQuestions: String

    init(meeting: Meeting) {
        self.meeting = meeting
        let summary = meeting.summary
        _overview = State(initialValue: summary?.overview ?? "")
        _keyPoints = State(initialValue: (summary?.keyPoints ?? []).joined(separator: "\n"))
        _decisions = State(initialValue: (summary?.decisions ?? []).joined(separator: "\n"))
        _actionItems = State(initialValue: (summary?.actionItems ?? [])
            .map { "\($0.task) | \($0.owner) | \($0.deadline)" }
            .joined(separator: "\n"))
        _openQuestions = State(initialValue: (summary?.openQuestions ?? []).joined(separator: "\n"))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Overview") {
                    TextEditor(text: $overview)
                        .frame(minHeight: 80)
                }
                Section {
                    TextEditor(text: $keyPoints)
                        .frame(minHeight: 80)
                } header: {
                    Text("Key Points")
                } footer: {
                    Text("One item per line.")
                }
                Section {
                    TextEditor(text: $decisions)
                        .frame(minHeight: 60)
                } header: {
                    Text("Decisions")
                } footer: {
                    Text("One item per line.")
                }
                Section {
                    TextEditor(text: $actionItems)
                        .frame(minHeight: 80)
                } header: {
                    Text("Action Items")
                } footer: {
                    Text("One per line, as: task | owner | deadline")
                }
                Section {
                    TextEditor(text: $openQuestions)
                        .frame(minHeight: 60)
                } header: {
                    Text("Open Questions")
                } footer: {
                    Text("One item per line.")
                }
            }
            .navigationTitle("Edit Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                }
            }
        }
    }

    private func save() {
        meeting.summary = MeetingSummary(
            overview: overview.trimmingCharacters(in: .whitespacesAndNewlines),
            keyPoints: Self.parseList(keyPoints),
            decisions: Self.parseList(decisions),
            actionItems: Self.parseActionItems(actionItems),
            openQuestions: Self.parseList(openQuestions),
            generatedAt: meeting.summary?.generatedAt ?? .now
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
