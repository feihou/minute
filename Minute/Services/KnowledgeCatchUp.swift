import Foundation
import SwiftData

/// The knowledge layer's catch-up loop (spec §5): extract facts from any
/// meeting not yet stamped, newest first, one at a time, only while the app
/// is active and the device is cool. Plumbing, not a feature — covers
/// retries, meetings from before extraction existed, bulk imports, and
/// future extractor upgrades with one mechanism.
@MainActor
@Observable
final class KnowledgeCatchUp {
    typealias Extractor = @MainActor (_ transcript: String, _ knownEntityNames: [String]) async throws -> [KnowledgeCandidate]

    /// Unstamped meetings remaining, for the m2 "catching up" row.
    private(set) var pendingCount = 0

    private let extract: Extractor
    private var running: Task<Void, Never>?
    /// Meetings that failed or were empty this session — skipped, not
    /// retried hot, so one permanently-refusing meeting can't
    /// head-of-line-block the queue. Cleared naturally at next launch.
    private var skippedThisSession: Set<UUID> = []

    init(extract: @escaping Extractor = { transcript, names in
        try await KnowledgeExtractionService().extract(transcript: transcript, knownEntityNames: names)
    }) {
        self.extract = extract
    }

    /// Starts the loop if it isn't running. Cheap to call often.
    func nudge(context: ModelContext) {
        guard running == nil else { return }
        running = Task { [self] in
            await run(context: context)
            running = nil
        }
    }

    /// Stops after the in-flight meeting. Call when the scene deactivates.
    func pause() {
        running?.cancel()
    }

    /// Test hook: resolves when the current loop (if any) has finished.
    func waitUntilIdle() async {
        await running?.value
    }

    private func run(context: ModelContext) async {
        while !Task.isCancelled {
            // Sustained ANE work on a warm phone throttles everything; wait
            // for the next nudge instead (spec §5).
            let thermal = ProcessInfo.processInfo.thermalState
            guard thermal == .nominal || thermal == .fair else { return }

            guard let meeting = nextPending(context: context) else {
                pendingCount = 0
                return
            }
            guard meeting.hasTranscript else {
                // Mid-transcription or genuinely silent: leave unstamped so a
                // transcript arriving later gets extracted; skip this session
                // so an empty import doesn't spin the loop.
                skippedThisSession.insert(meeting.id)
                continue
            }
            do {
                let names = knownEntityNames(context: context)
                let candidates = try await extract(meeting.timestampedTranscriptText, names)
                guard !meeting.isDeleted else { continue }
                try KnowledgeIngest.apply(candidates, from: meeting, context: context)
                meeting.knowledgeExtractedAt = .now
                try context.save()
            } catch is CancellationError {
                return
            } catch {
                // Transient (rate limit) and permanent (refusal) failures
                // both skip for this session and retry at next launch.
                skippedThisSession.insert(meeting.id)
            }
        }
    }

    private func nextPending(context: ModelContext) -> Meeting? {
        let descriptor = FetchDescriptor<Meeting>(
            predicate: #Predicate { $0.knowledgeExtractedAt == nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let pending = (try? context.fetch(descriptor)) ?? []
        pendingCount = pending.count
        return pending.first { !skippedThisSession.contains($0.id) }
    }

    private func knownEntityNames(context: ModelContext) -> [String] {
        let entities = (try? context.fetch(FetchDescriptor<KnowledgeEntity>())) ?? []
        return entities.filter { $0.redirectTo == nil }.flatMap { [$0.name] + $0.aliases }
    }
}
