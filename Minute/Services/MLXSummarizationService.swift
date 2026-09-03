import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import OSLog
// The #huggingFaceTokenizerLoader macro expands inline here, so its
// reference to Tokenizers needs the import in THIS file.
import Tokenizers

// MARK: - Catalog

/// A local summary model the user can download. The repo is the
/// mlx-community Hugging Face repository holding the 4-bit weights.
struct MLXSummaryModel: Identifiable, Equatable {
    let repoID: String
    let label: String
    let detail: String
    /// Approximate download size, shown before downloading.
    let approximateMegabytes: Int
    /// Minimum physical RAM in GB. Loading a model near the device's limit
    /// gets the app killed by the system instead of a clean error, so the
    /// picker refuses models the device can't hold.
    let minimumMemoryGigabytes: Int

    var id: String { repoID }
}

/// Curated subset of mlx-community — Qwen3 for its strong multilingual
/// notes (including Chinese), matching the Whisper transcription goal.
enum MLXModelCatalog {
    static let models: [MLXSummaryModel] = [
        MLXSummaryModel(
            repoID: "mlx-community/Qwen3-1.7B-4bit",
            label: "Qwen3 1.7B",
            detail: "Fast and light. Solid notes in many languages.",
            approximateMegabytes: 1_000,
            minimumMemoryGigabytes: 6
        ),
        MLXSummaryModel(
            repoID: "mlx-community/Qwen3-4B-4bit",
            label: "Qwen3 4B",
            detail: "Best quality. Needs a recent Pro iPhone.",
            approximateMegabytes: 2_300,
            minimumMemoryGigabytes: 8
        ),
    ]

    /// The best model this device can hold; the smallest as a fallback so
    /// the picker always has a selection to show.
    static var defaultModel: MLXSummaryModel {
        models.last(where: deviceSupports) ?? models[0]
    }

    static func model(for repoID: String) -> MLXSummaryModel? {
        models.first { $0.repoID == repoID }
    }

    /// Decimal thresholds sit safely below the binary sizes iOS reports
    /// (an "8 GB" iPhone reports ~8.59e9 bytes).
    static func deviceSupports(_ model: MLXSummaryModel) -> Bool {
        ProcessInfo.processInfo.physicalMemory >= UInt64(model.minimumMemoryGigabytes) * 1_000_000_000
    }
}

// MARK: - Store

/// Downloads, locates, and deletes summary models on disk. Models live in
/// Application Support (excluded from backups — they're re-downloadable)
/// under the HubCache layout swift-huggingface writes into.
enum MLXModelStore {
    static var baseDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MLXModels", directoryHint: .isDirectory)
        if !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            var url = base
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
        return base
    }

    /// Where HubCache places a repo.
    /// ponytail: mirrors the cache layout (models--org--name) instead of
    /// persisting resolved paths — revisit if swift-huggingface changes it.
    static func repoDirectory(for model: MLXSummaryModel) -> URL {
        baseDirectory.appending(
            path: "models--" + model.repoID.replacingOccurrences(of: "/", with: "--"),
            directoryHint: .isDirectory
        )
    }

    /// Written only after download() finishes the whole snapshot. Weights
    /// alone aren't proof of completeness: an interrupted download can leave
    /// one flushed shard behind, and loading such a partial snapshot would
    /// silently fetch the rest over the network mid-generation — which the
    /// Settings copy promises never happens.
    private static let completionMarkerName = ".minute-download-complete"

    static func completionMarker(for model: MLXSummaryModel) -> URL {
        repoDirectory(for: model).appending(path: completionMarkerName)
    }

    /// True when the snapshot completed AND still holds weights. ponytail:
    /// no checksums — a model corrupted after completion fails at load and
    /// the fix is delete + re-download.
    static func isDownloaded(_ model: MLXSummaryModel) -> Bool {
        guard FileManager.default.fileExists(atPath: completionMarker(for: model).path) else {
            return false
        }
        let directory = repoDirectory(for: model)
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return false
        }
        for case let file as URL in files where file.pathExtension == "safetensors" {
            return true
        }
        return false
    }

    static func delete(_ model: MLXSummaryModel) {
        try? FileManager.default.removeItem(at: repoDirectory(for: model))
    }

    /// Any bytes on disk for this repo — including a cancelled or failed
    /// partial download, which the user must still be able to delete: a
    /// disk-full failure can strand gigabytes that finishing the download
    /// could never reclaim.
    static func hasLocalData(_ model: MLXSummaryModel) -> Bool {
        FileManager.default.fileExists(atPath: repoDirectory(for: model).path)
    }

    static func hubClient() -> HubClient {
        HubClient(
            host: HubClient.defaultHost,
            tokenProvider: TokenProvider.none,
            cache: HubCache(cacheDirectory: baseDirectory)
        )
    }

    /// Streams the model (weights + tokenizer) from Hugging Face into the
    /// store; partially downloaded files are kept so a retry resumes.
    static func download(
        _ model: MLXSummaryModel,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        let resolved = try await resolve(
            configuration: ModelConfiguration(id: model.repoID),
            from: #hubDownloader(hubClient()),
            useLatest: false,
            progressHandler: { progress in
                let fraction = progress.fractionCompleted
                Task { @MainActor in onProgress(fraction) }
            }
        )
        // A cancel can be swallowed downstream: when the repo listing fails,
        // HubClient falls back to ANY cached snapshot directory with a
        // matching file, so a cancelled retry can "succeed" with partial
        // files on disk. Those must never earn the marker below.
        try Task.checkCancellation()
        // The same fallback fires on a plain network failure too (an offline
        // retry after an interrupted download), where no cancel is pending —
        // so also require the resolved snapshot to actually hold weights and
        // config before certifying it. ponytail: presence check, not a
        // manifest diff — a partial missing only a tokenizer file slips
        // through; read model.safetensors.index.json if that ever bites.
        let snapshot = (try? FileManager.default.contentsOfDirectory(
            at: resolved.modelDirectory, includingPropertiesForKeys: nil
        )) ?? []
        guard snapshot.contains(where: { $0.pathExtension == "safetensors" }),
              snapshot.contains(where: { $0.lastPathComponent == "config.json" }) else {
            throw IncompleteSnapshotFailure()
        }
        // Only a fully resolved snapshot earns the marker isDownloaded
        // needs — and a marker that can't be written (disk full at the very
        // end) must fail the download, or the UI reports success while
        // isDownloaded keeps rejecting the model forever.
        guard FileManager.default.createFile(atPath: completionMarker(for: model).path, contents: nil) else {
            throw MarkerWriteFailure()
        }
    }

    private struct MarkerWriteFailure: LocalizedError {
        var errorDescription: String? {
            "The download finished but couldn't be recorded — the device may be out of storage. Free up space and try again."
        }
    }

    private struct IncompleteSnapshotFailure: LocalizedError {
        var errorDescription: String? {
            "Some model files are still missing — check your connection and try again."
        }
    }
}

// MARK: - Job gate

/// Serializes local-model work across the whole app.
///
/// Each summarize job builds its own service instance and loads its own
/// 1-2.3 GB container (deliberately: keeping the weights resident between
/// occasional summaries is worse for memory pressure). Nothing else stops two
/// meetings from summarizing at once — MeetingJobs gates per meeting, and
/// Auto-Summarize plus a manual Generate on another meeting is two clicks
/// away — and two containers resident together is what pushes the app past
/// the foreground memory limit on the very devices the catalog's floors
/// admit, killing it with both jobs lost and no failure recorded.
actor MLXJobGate {
    static let shared = MLXJobGate()

    /// Progress text a queued job reports, so the summary section explains
    /// the wait instead of sitting on "Loading the summary model…".
    static let waitingStatus = "Waiting for another local-model job to finish…"

    private var isRunning = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Runs `body` once no other local-model job is running, calling
    /// `onWaiting` first when this job has to queue. The gate reopens as soon
    /// as `body` returns OR throws — a failed job must never wedge the queue.
    ///
    /// `body` is a labelled parameter, not a trailing one: callers pass two
    /// closures, and a labelled-plus-trailing pair is what SwiftLint's
    /// multiple_closures_with_trailing_closure rejects.
    nonisolated func run<T>(
        onWaiting: @escaping @MainActor @Sendable () -> Void,
        body: @MainActor () async throws -> T
    ) async throws -> T {
        await acquire(onWaiting: onWaiting)
        do {
            let value = try await body()
            await release()
            return value
        } catch {
            await release()
            throw error
        }
    }

    private func acquire(onWaiting: @escaping @MainActor @Sendable () -> Void) async {
        if isRunning {
            await onWaiting()
        }
        // A loop, not a single suspension: release() wakes one waiter, but a
        // job arriving in between can take the gate first.
        while isRunning {
            await withCheckedContinuation { waiting.append($0) }
        }
        isRunning = true
    }

    private func release() {
        isRunning = false
        guard !waiting.isEmpty else { return }
        waiting.removeFirst().resume()
    }
}

// MARK: - Service

/// Generates structured meeting summaries with a user-downloaded local model
/// (MLX). Shares the Apple engine's grounding rules and normalization; the
/// structured output comes from strict-JSON prompting instead of guided
/// generation, parsed leniently.
@MainActor
final class MLXSummarizationService: SummarizationEngine {
    private static let logger = Logger(subsystem: "com.minuteapp.Minute", category: "MLXSummarization")

    /// Nil when the selected model is ready; otherwise a user-facing reason.
    static var availabilityMessage: String? {
        #if targetEnvironment(simulator)
        return "The local summary model can't run in the Simulator. Switch to Apple Intelligence in Settings."
        #else
        guard let model = MLXModelCatalog.model(for: AppSettings.localSummaryModel) else {
            return "The selected summary model is no longer offered. Choose another in Settings → Summary Model."
        }
        guard MLXModelCatalog.deviceSupports(model) else {
            return "This iPhone doesn't have enough memory for \(model.label). Choose a smaller model in Settings → Summary Model."
        }
        guard MLXModelStore.isDownloaded(model) else {
            return "The summary model isn't downloaded yet. Get it in Settings → Summary Model, or switch back to Apple Intelligence."
        }
        return nil
        #endif
    }

    var availabilityMessage: String? { Self.availabilityMessage }

    /// English language name the notes should be written in; nil means
    /// "match the meeting's language".
    private let language: String?
    /// Cached per service instance (all chunks of one meeting reuse it), and
    /// deliberately NOT app-wide: keeping 1–2.3 GB of weights resident
    /// between occasional summaries is worse for memory pressure — notably
    /// alongside Whisper's model — than reloading per job.
    private var container: ModelContainer?

    init(language: String?) {
        self.language = language
    }

    func summarize(
        transcript: String,
        template: SummaryTemplate,
        context: String,
        onProgress: (@MainActor @Sendable (String) -> Void)?
    ) async throws -> MeetingSummary {
        if let message = availabilityMessage {
            throw SummarizerError.unavailable(message)
        }
        let chunks = TranscriptChunker.chunks(from: transcript, maxChars: TranscriptChunker.defaultMaxChars)
        guard !chunks.isEmpty else { throw SummarizerError.emptyTranscript }

        // One local-model job at a time, app-wide: see MLXJobGate. Both
        // closures are labelled arguments — a labelled closure plus a
        // trailing one trips SwiftLint's
        // multiple_closures_with_trailing_closure, which CI enforces.
        return try await MLXJobGate.shared.run(
            onWaiting: { onProgress?(MLXJobGate.waitingStatus) },
            body: {
                try await self.generate(chunks: chunks, template: template, context: context, onProgress: onProgress)
            }
        )
    }

    /// The whole generation, from model load to finished notes, run while
    /// holding MLXJobGate.
    private func generate(
        chunks: [String],
        template: SummaryTemplate,
        context: String,
        onProgress: (@MainActor @Sendable (String) -> Void)?
    ) async throws -> MeetingSummary {
        // The weights go the moment this job ends: the gate opens for the
        // next job immediately afterwards, and two resident containers is the
        // failure the gate exists to prevent. Spelled `self.` because a local
        // `let container` is declared below and this defer clears the
        // instance property, not that local.
        defer { self.container = nil }
        // A job cancelled while it queued behind another must not start a
        // full generation now that its turn came.
        try Task.checkCancellation()

        onProgress?("Loading the summary model…")
        // Outside the do/catch below, which only wraps generation: a corrupt
        // or half-downloaded snapshot would otherwise reach the summary
        // section as a raw MLX or URL error.
        let container: ModelContainer
        do {
            container = try await loadedContainer()
        } catch let error as SummarizerError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Self.logger.error("Local summary model load failed: \(error.localizedDescription)")
            throw SummarizerError.generationFailed(
                "The local summary model couldn't be loaded. Delete and re-download it in Settings → Summary Model, or switch to Apple Intelligence."
            )
        }
        let contextBlock = SummarizationService.contextBlock(from: context).map { "\n\($0)\n" } ?? ""

        do {
            if chunks.count == 1 {
                return try await summarizeWhole(chunks[0], template: template, contextBlock: contextBlock, container: container)
            }
            var notes: [LocalChunkNotes] = []
            var skipped = 0
            for (index, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                await onProgress?("Reading part \(index + 1) of \(chunks.count)…")
                do {
                    notes.append(try await extractNotes(from: chunk, part: index + 1, of: chunks.count, contextBlock: contextBlock, container: container))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // One bad stretch must not sink the whole meeting.
                    Self.logger.error("Chunk summarization failed: \(error.localizedDescription)")
                    skipped += 1
                }
            }
            guard !notes.isEmpty else {
                throw SummarizerError.generationFailed(Self.unreadableMessage)
            }
            try Task.checkCancellation()
            await onProgress?("Combining notes…")
            var summary: MeetingSummary
            do {
                summary = try await merge(notes, template: template, contextBlock: contextBlock, container: container)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Every part already succeeded, at minutes of on-device
                // generation apiece. A garbled merge or condense reply —
                // the largest prompt of the run, and the one a small
                // model misformats most — degrades the summary (no
                // overview, title, or template sections) instead of
                // destroying it, the same finish line the Apple engine
                // protects.
                // MLX has no typed cancellation, so a cancel that landed
                // inside the generation can arrive here as an ordinary
                // error — folding it would save a summary the user just
                // asked not to have.
                try Task.checkCancellation()
                Self.logger.error("Local merge failed, combining notes in code: \(error.localizedDescription)")
                summary = try Self.degradedSummary(from: notes)
            }
            if skipped > 0 {
                summary.skippedParts = skipped
            }
            return summary
        } catch let error as SummarizerError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SummarizerError.generationFailed(
                "The local model couldn't summarize this meeting: \(error.localizedDescription)"
            )
        }
    }

    // MARK: Model loading

    /// Loads through the same downloader path as Settings' download — with
    /// the snapshot already cached this is an offline cache hit, and it
    /// avoids hardcoding HubCache's snapshot-revision layout.
    private func loadedContainer() async throws -> ModelContainer {
        if let container { return container }
        guard let model = MLXModelCatalog.model(for: AppSettings.localSummaryModel) else {
            throw SummarizerError.unavailable("The selected summary model is no longer offered. Choose another in Settings → Summary Model.")
        }
        let loaded = try await LLMModelFactory.shared.loadContainer(
            from: #hubDownloader(MLXModelStore.hubClient()),
            using: #huggingFaceTokenizerLoader(),
            configuration: ModelConfiguration(id: model.repoID)
        )
        container = loaded
        return loaded
    }

    // MARK: Prompts

    private static let unreadableMessage =
        "The local model returned an unreadable answer. Try again, or switch to Apple Intelligence in Settings."

    /// Shared grounding rules plus the JSON-only contract. "/no_think" is
    /// Qwen3's soft switch against reasoning preambles; other models ignore
    /// it, and the extractor strips <think> blocks anyway.
    private var instructions: String {
        SummarizationService.groundingRules(language: language) + """

        Output format:
        - Respond with ONLY one JSON object. No prose, no markdown fences, no comments.
        - Use exactly the keys requested. Every key must be present; use [] for empty lists.
        /no_think
        """
    }

    private func session(_ container: ModelContainer) -> ChatSession {
        ChatSession(
            container,
            instructions: instructions,
            generateParameters: GenerateParameters(maxTokens: 2_048, temperature: 0.3)
        )
    }

    private static let standardSchema = """
        {"overview": string, "title": string, "keyPoints": [string], "decisions": [string], \
        "actionItems": [{"task": string, "owner": string, "deadline": string}], \
        "openQuestions": [string], "speakerPerspectives": [{"speaker": string, "points": [string]}]}
        """

    private static let notesSchema = """
        {"keyPoints": [string], "decisions": [string], \
        "actionItems": [{"task": string, "owner": string, "deadline": string}], \
        "openQuestions": [string], "speakerPerspectives": [{"speaker": string, "points": [string]}]}
        """

    private static let templatedSchema = """
        {"overview": string, "title": string, "sections": [{"name": string, "items": [string]}], \
        "actionItems": [{"task": string, "owner": string, "deadline": string}], \
        "speakerPerspectives": [{"speaker": string, "points": [string]}]}
        """

    private func sectionBlock(for template: SummaryTemplate) -> String {
        """
        Organize the notes into exactly these sections, in this order, using these exact section names:
        \(template.sections.map { "- \($0.name): \($0.definition)." }.joined(separator: "\n"))
        If nothing in the meeting fits a section, give it an empty items list.
        """
    }

    // MARK: Generation passes

    private func summarizeWhole(
        _ transcript: String,
        template: SummaryTemplate,
        contextBlock: String,
        container: ModelContainer
    ) async throws -> MeetingSummary {
        let schema = template.isStandard ? Self.standardSchema : Self.templatedSchema
        let section = template.isStandard ? "" : "\(sectionBlock(for: template))\n"
        let prompt = """
            Create structured notes for this meeting transcript.
            \(section)\(contextBlock)
            Return JSON of exactly this shape:
            \(schema)

            <transcript>
            \(transcript)
            </transcript>
            """
        let reply = try await session(container).respond(to: prompt)
        if template.isStandard {
            let draft: LocalSummaryDraft = try Self.decode(reply)
            return try Self.validated(draft.meetingSummary())
        }
        let draft: LocalTemplatedDraft = try Self.decode(reply)
        return try Self.validated(draft.meetingSummary(template: template))
    }

    /// A structurally empty reply ("{}", or only unrecognized keys) decodes
    /// "successfully" because every draft field is optional — but saving it
    /// would silently replace the Generate empty-state with blank notes.
    private static func validated(_ summary: MeetingSummary) throws -> MeetingSummary {
        let hasContent = !summary.overview.isEmpty
            || !summary.keyPoints.isEmpty
            || !summary.decisions.isEmpty
            || !summary.actionItems.isEmpty
            || !summary.openQuestions.isEmpty
            || (summary.sections ?? []).contains { !$0.items.isEmpty }
            || summary.speakerPerspectives != nil
        guard hasContent else {
            throw SummarizerError.generationFailed(unreadableMessage)
        }
        return summary
    }

    private func extractNotes(
        from chunk: String,
        part: Int,
        of total: Int,
        contextBlock: String,
        container: ModelContainer
    ) async throws -> LocalChunkNotes {
        let prompt = """
            Extract structured notes from part \(part) of \(total) of a meeting transcript. \
            Parts overlap slightly and this part may begin or end mid-discussion — \
            note only what this part actually shows.
            \(contextBlock)
            Return JSON of exactly this shape:
            \(Self.notesSchema)

            <transcript>
            \(chunk)
            </transcript>
            """
        // A fresh session per chunk keeps each request small and independent.
        let reply = try await session(container).respond(to: prompt)
        let notes: LocalChunkNotes = try Self.decode(reply)
        // Counted as a skipped part by the caller — silently accepting it
        // would drop this chunk's content with no accounting at all.
        guard !notes.ignoredSchema else {
            throw SummarizerError.generationFailed(Self.unreadableMessage)
        }
        return notes
    }

    /// Keeps the merge prompt inside the local models' context windows even
    /// at the worst-case ~1 token per character of CJK text (Qwen3's 32k
    /// window, minus instructions, schema, and output room). English notes
    /// condense earlier than strictly needed — correctness for the
    /// multilingual path outranks a saved condense pass.
    private static let mergeCharBudget = 20_000

    private func merge(
        _ notes: [LocalChunkNotes],
        template: SummaryTemplate,
        contextBlock: String,
        container: ModelContainer
    ) async throws -> MeetingSummary {
        // Condense in groups until the combined notes fit one request —
        // the same safety net the Apple engine carries.
        var current = notes
        while current.count > 1, Self.rendered(current).count > Self.mergeCharBudget {
            var reduced: [LocalChunkNotes] = []
            for group in stride(from: 0, to: current.count, by: 4).map({ Array(current[$0..<min($0 + 4, current.count)]) }) {
                try Task.checkCancellation()
                if group.count == 1 {
                    reduced.append(group[0])
                } else {
                    reduced.append(try await condense(group, contextBlock: contextBlock, container: container))
                }
            }
            current = reduced
        }

        let schema = template.isStandard ? Self.standardSchema : Self.templatedSchema
        let section = template.isStandard ? "" : "\(sectionBlock(for: template))\n"
        let prompt = """
            These are notes taken from consecutive, overlapping parts of one meeting. \
            Merge them into a single summary of the whole meeting:
            - The parts overlap, so expect repeats: combine duplicate or overlapping items into one, \
            keeping the most specific wording and preferring versions that name an owner or deadline.
            - Drop any open question that another part shows was answered.
            - Merge speaker perspectives into one entry per speaker, keeping their most specific points.
            - Keep the wording faithful to the notes and do not add anything new.
            \(section)\(contextBlock)
            Return JSON of exactly this shape:
            \(schema)

            Notes:
            \(Self.rendered(current))
            """
        let reply = try await session(container).respond(to: prompt)
        if template.isStandard {
            let draft: LocalSummaryDraft = try Self.decode(reply)
            return try Self.validated(draft.meetingSummary())
        }
        let draft: LocalTemplatedDraft = try Self.decode(reply)
        return try Self.validated(draft.meetingSummary(template: template))
    }

    private func condense(
        _ notes: [LocalChunkNotes],
        contextBlock: String,
        container: ModelContainer
    ) async throws -> LocalChunkNotes {
        let prompt = """
            These are notes from consecutive, overlapping parts of one meeting. \
            Merge them into one set of notes: combine duplicates keeping the most specific wording, \
            drop open questions that another part answered, and do not add anything new.
            \(contextBlock)
            Return JSON of exactly this shape:
            \(Self.notesSchema)

            Notes:
            \(Self.rendered(notes))
            """
        let reply = try await session(container).respond(to: prompt)
        let condensed: LocalChunkNotes = try Self.decode(reply)
        // A schema-ignoring condense reply would silently drop the whole
        // group's content — fail the summary instead.
        guard !condensed.ignoredSchema else {
            throw SummarizerError.generationFailed(Self.unreadableMessage)
        }
        return condensed
    }

    private static func rendered(_ notes: [LocalChunkNotes]) -> String {
        notes.enumerated().map { index, note in
            var lines = ["Part \(index + 1):"]
            let keyPoints = note.keyPoints ?? []
            if !keyPoints.isEmpty {
                lines.append("Key points:")
                lines.append(contentsOf: keyPoints.map { "- \($0)" })
            }
            let decisions = note.decisions ?? []
            if !decisions.isEmpty {
                lines.append("Decisions:")
                lines.append(contentsOf: decisions.map { "- \($0)" })
            }
            let actionItems = note.actionItems ?? []
            if !actionItems.isEmpty {
                lines.append("Action items:")
                lines.append(contentsOf: actionItems.map {
                    "- \($0.task ?? "") (owner: \($0.owner ?? ""), deadline: \($0.deadline ?? ""))"
                })
            }
            let openQuestions = note.openQuestions ?? []
            if !openQuestions.isEmpty {
                lines.append("Open questions:")
                lines.append(contentsOf: openQuestions.map { "- \($0)" })
            }
            let perspectives = note.speakerPerspectives ?? []
            if !perspectives.isEmpty {
                lines.append("Speaker perspectives:")
                lines.append(contentsOf: perspectives.map {
                    "- \($0.speaker ?? ""): \(($0.points ?? []).joined(separator: "; "))"
                })
            }
            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    // MARK: Code-level fallback

    /// Folds chunk notes together in code — concatenate, dedupe, group
    /// speakers — for when the model garbles the one request it is already
    /// too late to retry. Loses the rephrasing, keeps every fact. The Apple
    /// engine degrades exactly this way on a refusal
    /// (SummarizationService.mechanicallyCombined).
    static func mechanicallyCombined(_ notes: [LocalChunkNotes]) -> LocalChunkNotes {
        var actionItems: [LocalActionItem] = []
        for item in notes.flatMap({ $0.actionItems ?? [] }) {
            let task = (item.task ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !task.isEmpty else { continue }
            // Same wording with a conflicting specified owner or deadline is
            // two commitments, not overlap — keep both.
            if let index = actionItems.firstIndex(where: {
                ($0.task ?? "").caseInsensitiveCompare(task) == .orderedSame
                    && !fieldsConflict($0.owner, item.owner)
                    && !fieldsConflict($0.deadline, item.deadline)
            }) {
                // Overlapping parts repeat tasks; keep the copy that names an
                // owner or deadline.
                if SummarizationService.normalizedField(actionItems[index].owner ?? "") == ActionItem.notSpecified {
                    actionItems[index].owner = item.owner
                }
                if SummarizationService.normalizedField(actionItems[index].deadline ?? "") == ActionItem.notSpecified {
                    actionItems[index].deadline = item.deadline
                }
            } else {
                actionItems.append(LocalActionItem(task: task, owner: item.owner, deadline: item.deadline))
            }
        }

        var perspectives: [LocalPerspective] = []
        for perspective in notes.flatMap({ $0.speakerPerspectives ?? [] }) {
            let speaker = (perspective.speaker ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !speaker.isEmpty else { continue }
            if let index = perspectives.firstIndex(where: { ($0.speaker ?? "").caseInsensitiveCompare(speaker) == .orderedSame }) {
                perspectives[index].points = SummarizationService.cleaned((perspectives[index].points ?? []) + (perspective.points ?? []))
            } else {
                perspectives.append(LocalPerspective(speaker: speaker, points: SummarizationService.cleaned(perspective.points ?? [])))
            }
        }

        return LocalChunkNotes(
            keyPoints: SummarizationService.cleaned(notes.flatMap { $0.keyPoints ?? [] }),
            decisions: SummarizationService.cleaned(notes.flatMap { $0.decisions ?? [] }),
            actionItems: actionItems,
            openQuestions: SummarizationService.cleaned(notes.flatMap { $0.openQuestions ?? [] }),
            speakerPerspectives: perspectives
        )
    }

    /// True when both values are specified and disagree — e.g. the same task
    /// wording owned by two different people.
    private static func fieldsConflict(_ first: String?, _ second: String?) -> Bool {
        let lhs = SummarizationService.normalizedField(first ?? "")
        let rhs = SummarizationService.normalizedField(second ?? "")
        return lhs != ActionItem.notSpecified && rhs != ActionItem.notSpecified
            && lhs.caseInsensitiveCompare(rhs) != .orderedSame
    }

    /// The no-model fallback summary: combined notes with an empty overview
    /// and no suggested title — the detail view hides both when empty, so the
    /// notes never claim a model wrote something it didn't.
    static func mechanicalSummary(from notes: [LocalChunkNotes]) -> MeetingSummary {
        let combined = mechanicallyCombined(notes)
        return MeetingSummary(
            overview: "",
            keyPoints: combined.keyPoints ?? [],
            decisions: combined.decisions ?? [],
            actionItems: (combined.actionItems ?? []).normalized(),
            openQuestions: combined.openQuestions ?? [],
            generatedAt: .now,
            suggestedTitle: nil,
            speakerPerspectives: (combined.speakerPerspectives ?? []).normalized()
        )
    }

    /// The fold is only a rescue when there is something in it to rescue.
    /// Explicitly empty arrays are a valid "nothing noteworthy in this part",
    /// so every part can succeed and still leave nothing to combine — and a
    /// summary with no content at all would replace the meeting's Generate
    /// empty-state with blank notes. Same guard as a model-written summary:
    /// an empty fold rethrows the unreadable-merge error instead of saving
    /// over the affordance the user needs to try again.
    static func degradedSummary(from notes: [LocalChunkNotes]) throws -> MeetingSummary {
        try validated(mechanicalSummary(from: notes))
    }

    // MARK: JSON handling

    static func decode<T: Decodable>(_ reply: String) throws -> T {
        guard let data = extractJSONObject(from: reply) else {
            throw SummarizerError.generationFailed(unreadableMessage)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw SummarizerError.generationFailed(unreadableMessage)
        }
    }

    /// Pulls the first balanced JSON object out of a model reply, tolerating
    /// reasoning preambles, <think> blocks, and markdown fences around it.
    static func extractJSONObject(from text: String) -> Data? {
        var cleaned = text
        // ponytail: first-open pairs with first-close, so truly nested think
        // tags leave a stray "</think>" behind — which degrades safely (the
        // scanner either skips it or the decoder rejects the fragment).
        while let start = cleaned.range(of: "<think>"), let end = cleaned.range(of: "</think>"),
              start.lowerBound < end.upperBound {
            cleaned.removeSubrange(start.lowerBound..<end.upperBound)
        }
        // An unmatched <think> means generation ran out of budget while still
        // reasoning — any JSON inside is a discarded draft, not the answer.
        // Dropping it makes the reply fail parsing (a clean, visible error)
        // instead of silently shipping a plausible-but-wrong summary.
        if let unterminated = cleaned.range(of: "<think>") {
            cleaned.removeSubrange(unterminated.lowerBound..<cleaned.endIndex)
        }

        guard let start = cleaned.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < cleaned.endIndex {
            let character = cleaned[index]
            if escaped {
                escaped = false
            } else if inString {
                if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                switch character {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        return String(cleaned[start...index]).data(using: .utf8)
                    }
                default: break
                }
            }
            index = cleaned.index(after: index)
        }
        return nil
    }
}

// MARK: - Lenient draft types

/// Every field optional: a small model that omits an empty list shouldn't
/// sink the whole summary. Normalization shares the Apple engine's helpers
/// so both engines honor the same output contract.
struct LocalActionItem: Codable {
    var task: String?
    var owner: String?
    var deadline: String?
}

struct LocalPerspective: Codable {
    var speaker: String?
    var points: [String]?
}

struct LocalChunkNotes: Codable {
    var keyPoints: [String]?
    var decisions: [String]?
    var actionItems: [LocalActionItem]?
    var openQuestions: [String]?
    var speakerPerspectives: [LocalPerspective]?

    /// True when NO expected key was present at all ("{}", or only
    /// unrecognized keys) — the model ignored the schema. Distinct from
    /// explicitly empty arrays, which are an honest "this chunk had
    /// nothing noteworthy" and stay valid.
    var ignoredSchema: Bool {
        keyPoints == nil && decisions == nil && actionItems == nil
            && openQuestions == nil && speakerPerspectives == nil
    }
}

struct LocalSummaryDraft: Codable {
    var overview: String?
    var title: String?
    var keyPoints: [String]?
    var decisions: [String]?
    var actionItems: [LocalActionItem]?
    var openQuestions: [String]?
    var speakerPerspectives: [LocalPerspective]?

    func meetingSummary() -> MeetingSummary {
        MeetingSummary(
            overview: (overview ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            keyPoints: SummarizationService.cleaned(keyPoints ?? []),
            decisions: SummarizationService.cleaned(decisions ?? []),
            actionItems: (actionItems ?? []).normalized(),
            openQuestions: SummarizationService.cleaned(openQuestions ?? []),
            generatedAt: .now,
            suggestedTitle: SummarizationService.normalizedTitle(title ?? ""),
            speakerPerspectives: (speakerPerspectives ?? []).normalized()
        )
    }
}

struct LocalSection: Codable {
    var name: String?
    var items: [String]?
}

struct LocalTemplatedDraft: Codable {
    var overview: String?
    var title: String?
    var sections: [LocalSection]?
    var actionItems: [LocalActionItem]?
    var speakerPerspectives: [LocalPerspective]?

    func meetingSummary(template: SummaryTemplate) -> MeetingSummary {
        MeetingSummary(
            overview: (overview ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            keyPoints: [],
            decisions: [],
            actionItems: (actionItems ?? []).normalized(),
            openQuestions: [],
            generatedAt: .now,
            suggestedTitle: SummarizationService.normalizedTitle(title ?? ""),
            sections: SummarizationService.reconciledSections(
                (sections ?? []).compactMap { section in
                    let title = (section.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty else { return nil }
                    return SummarySection(title: title, items: SummarizationService.cleaned(section.items ?? []))
                },
                with: template
            ),
            speakerPerspectives: (speakerPerspectives ?? []).normalized()
        )
    }
}

extension [LocalActionItem] {
    /// Mirrors the Apple engine's action-item contract, via the shared field
    /// helpers.
    func normalized() -> [ActionItem] {
        compactMap { item in
            let task = (item.task ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !task.isEmpty else { return nil }
            return ActionItem(
                task: task,
                owner: SummarizationService.normalizedField(item.owner ?? ""),
                deadline: SummarizationService.normalizedField(item.deadline ?? "")
            )
        }
    }
}

extension [LocalPerspective] {
    func normalized() -> [SpeakerPerspective]? {
        let perspectives = compactMap { draft -> SpeakerPerspective? in
            let name = (draft.speaker ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let points = SummarizationService.cleaned(draft.points ?? [])
            guard !name.isEmpty, !points.isEmpty else { return nil }
            return SpeakerPerspective(speaker: name, points: points)
        }
        return perspectives.isEmpty ? nil : perspectives
    }
}
