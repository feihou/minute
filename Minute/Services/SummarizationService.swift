import Foundation
import FoundationModels

// MARK: - Generable output types

@Generable(description: "Structured notes covering one portion of a meeting transcript.")
struct ChunkNotes {
    @Guide(description: "The most important points discussed. Empty if none were discussed.")
    var keyPoints: [String]

    @Guide(description: "Decisions that were explicitly made in the transcript. Empty if none.")
    var decisions: [String]

    @Guide(description: "Action items explicitly mentioned in the transcript. Empty if none.")
    var actionItems: [DraftActionItem]

    @Guide(description: "Questions raised in the transcript that were not answered. Empty if none.")
    var openQuestions: [String]
}

@Generable(description: "A single action item from a meeting.")
struct DraftActionItem {
    @Guide(description: "What needs to be done, in one short sentence.")
    var task: String

    @Guide(description: "The person responsible, exactly as named in the transcript, or 'Not specified' when no owner was stated.")
    var owner: String

    @Guide(description: "The deadline exactly as stated in the transcript, or 'Not specified' when no deadline was stated.")
    var deadline: String
}

@Generable(description: "A complete structured summary of a meeting.")
struct SummaryDraft {
    @Guide(description: "A concise overview of the meeting in 2 to 4 sentences.")
    var overview: String

    @Guide(description: "The most important points, at most 8. Empty if none.")
    var keyPoints: [String]

    @Guide(description: "Decisions that were explicitly made. Empty if none.")
    var decisions: [String]

    @Guide(description: "Action items explicitly mentioned. Empty if none.")
    var actionItems: [DraftActionItem]

    @Guide(description: "Questions raised but not answered. Empty if none.")
    var openQuestions: [String]
}

// MARK: - Service

enum SummarizerError: LocalizedError {
    case unavailable(String)
    case emptyTranscript
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            return message
        case .emptyTranscript:
            return "There's no transcript to summarize."
        case .generationFailed(let message):
            return message
        }
    }
}

/// Generates structured meeting summaries with the on-device Apple Intelligence
/// model. Long transcripts are chunked, noted per chunk, then merged — nothing
/// ever leaves the device.
struct SummarizationService {
    /// Nil when the model is ready; otherwise a user-facing explanation.
    static var availabilityMessage: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This iPhone doesn't support Apple Intelligence, so summaries can't be generated on device."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in Settings to generate summaries on device."
        case .unavailable(.modelNotReady):
            return "The on-device model is still getting ready. Try again in a bit."
        case .unavailable:
            return "The on-device model is currently unavailable."
        }
    }

    private static let groundingRules = """
        You turn meeting transcripts into faithful structured notes.
        Use ONLY information stated in the text you are given.
        Never invent decisions, owners, deadlines, names, or facts.
        If an action item's owner is not clearly stated, use exactly "Not specified".
        If an action item's deadline is not clearly stated, use exactly "Not specified".
        Keep every item short, concrete, and faithful to the source text.
        """

    private let options = GenerationOptions(temperature: 0.3)

    func summarize(transcript: String) async throws -> MeetingSummary {
        if let message = Self.availabilityMessage {
            throw SummarizerError.unavailable(message)
        }
        // Characters-per-token varies wildly by language (CJK is ~1:1), so the
        // chunk budget adapts: halve on context overflow down to a floor that
        // is safely inside the 4,096-token window for any script.
        var maxChars = TranscriptChunker.defaultMaxChars
        while true {
            do {
                return try await summarize(transcript: transcript, maxChars: maxChars)
            } catch let error as LanguageModelSession.GenerationError {
                if case .exceededContextWindowSize = error, maxChars > 750 {
                    maxChars /= 2
                    continue
                }
                throw SummarizerError.generationFailed(friendlyMessage(for: error))
            }
        }
    }

    private func summarize(transcript: String, maxChars: Int) async throws -> MeetingSummary {
        let chunks = TranscriptChunker.chunks(from: transcript, maxChars: maxChars)
        guard !chunks.isEmpty else { throw SummarizerError.emptyTranscript }

        let draft: SummaryDraft
        if chunks.count == 1 {
            draft = try await summarizeWhole(chunks[0])
        } else {
            var notes: [ChunkNotes] = []
            for (index, chunk) in chunks.enumerated() {
                notes.append(try await extractNotes(from: chunk, part: index + 1, of: chunks.count))
            }
            draft = try await merge(notes, maxChars: maxChars)
        }
        return normalized(draft)
    }

    private func summarizeWhole(_ transcript: String) async throws -> SummaryDraft {
        let session = LanguageModelSession(instructions: Self.groundingRules)
        let prompt = "Summarize this meeting transcript.\n\nTranscript:\n\(transcript)"
        return try await session.respond(to: prompt, generating: SummaryDraft.self, options: options).content
    }

    private func extractNotes(from chunk: String, part: Int, of total: Int) async throws -> ChunkNotes {
        // A fresh session per chunk keeps each request inside the context window.
        let session = LanguageModelSession(instructions: Self.groundingRules)
        let prompt = """
            Extract structured notes from part \(part) of \(total) of a meeting transcript.

            Transcript part:
            \(chunk)
            """
        return try await session.respond(to: prompt, generating: ChunkNotes.self, options: options).content
    }

    private func merge(_ notes: [ChunkNotes], maxChars: Int) async throws -> SummaryDraft {
        // Condense in groups until the combined notes fit one request.
        var current = notes
        while current.count > 1, rendered(current).count > maxChars {
            var reduced: [ChunkNotes] = []
            for group in stride(from: 0, to: current.count, by: 3).map({ Array(current[$0..<min($0 + 3, current.count)]) }) {
                if group.count == 1 {
                    reduced.append(group[0])
                } else {
                    reduced.append(try await condense(group))
                }
            }
            current = reduced
        }

        let session = LanguageModelSession(instructions: Self.groundingRules)
        let prompt = """
            These are notes taken from consecutive parts of one meeting. \
            Merge them into a single summary of the whole meeting. \
            Combine duplicates, keep the wording faithful, and do not add anything new.

            Notes:
            \(rendered(current))
            """
        return try await session.respond(to: prompt, generating: SummaryDraft.self, options: options).content
    }

    private func condense(_ notes: [ChunkNotes]) async throws -> ChunkNotes {
        let session = LanguageModelSession(instructions: Self.groundingRules)
        let prompt = """
            These are notes from consecutive parts of one meeting. \
            Merge them into one set of notes. Combine duplicates and do not add anything new.

            Notes:
            \(rendered(notes))
            """
        return try await session.respond(to: prompt, generating: ChunkNotes.self, options: options).content
    }

    private func rendered(_ notes: [ChunkNotes]) -> String {
        notes.enumerated().map { index, note in
            var lines = ["Part \(index + 1):"]
            if !note.keyPoints.isEmpty {
                lines.append("Key points:")
                lines.append(contentsOf: note.keyPoints.map { "- \($0)" })
            }
            if !note.decisions.isEmpty {
                lines.append("Decisions:")
                lines.append(contentsOf: note.decisions.map { "- \($0)" })
            }
            if !note.actionItems.isEmpty {
                lines.append("Action items:")
                lines.append(contentsOf: note.actionItems.map { "- \($0.task) (owner: \($0.owner), deadline: \($0.deadline))" })
            }
            if !note.openQuestions.isEmpty {
                lines.append("Open questions:")
                lines.append(contentsOf: note.openQuestions.map { "- \($0)" })
            }
            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    /// Trims, drops empties, dedupes, and enforces the "Not specified" contract.
    private func normalized(_ draft: SummaryDraft) -> MeetingSummary {
        MeetingSummary(
            overview: draft.overview.trimmingCharacters(in: .whitespacesAndNewlines),
            keyPoints: cleaned(draft.keyPoints),
            decisions: cleaned(draft.decisions),
            actionItems: draft.actionItems.compactMap { item in
                let task = item.task.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !task.isEmpty else { return nil }
                return ActionItem(
                    task: task,
                    owner: normalizedField(item.owner),
                    deadline: normalizedField(item.deadline)
                )
            },
            openQuestions: cleaned(draft.openQuestions),
            generatedAt: .now
        )
    }

    private func cleaned(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    private func normalizedField(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased() == "not specified" || trimmed.lowercased() == "none" || trimmed.lowercased() == "unknown" {
            return ActionItem.notSpecified
        }
        return trimmed
    }

    private func friendlyMessage(for error: Error) -> String {
        if let generationError = error as? LanguageModelSession.GenerationError {
            switch generationError {
            case .guardrailViolation:
                return "The on-device model declined to summarize this content."
            case .exceededContextWindowSize:
                return "This meeting is too long to summarize in one pass. Please try again."
            case .assetsUnavailable:
                return "The on-device model isn't ready. Try again in a bit."
            default:
                break
            }
        }
        return "Summarization failed: \(error.localizedDescription)"
    }
}
