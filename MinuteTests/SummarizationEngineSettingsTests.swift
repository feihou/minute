import Foundation
import Testing
@testable import Minute

/// The engine choice and local-model catalog back the Settings picker and
/// the SummarizationEngines factory.
///
/// Serialized: these tests mutate shared UserDefaults keys.
@Suite(.serialized)
struct SummarizationEngineSettingsTests {
    private func withDefault(_ key: String, set value: String?, _ body: () -> Void) {
        let previous = UserDefaults.standard.string(forKey: key)
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        body()
    }

    @Test("Apple Intelligence is the default engine")
    func defaultsToApple() {
        withDefault(AppSettings.summarizationEngineKey, set: nil) {
            #expect(AppSettings.summarizationEngine == .appleIntelligence)
        }
    }

    @Test("A stored local-model choice is read back")
    func readsLocalChoice() {
        withDefault(AppSettings.summarizationEngineKey, set: "local") {
            #expect(AppSettings.summarizationEngine == .localModel)
        }
    }

    @Test("An unknown stored value falls back to Apple Intelligence")
    func unknownEngineFallsBack() {
        withDefault(AppSettings.summarizationEngineKey, set: "garbage") {
            #expect(AppSettings.summarizationEngine == .appleIntelligence)
        }
    }

    @Test("Local model defaults to the catalog's device-appropriate pick")
    func localModelDefaultsToCatalog() {
        withDefault(AppSettings.localSummaryModelKey, set: nil) {
            #expect(AppSettings.localSummaryModel == MLXModelCatalog.defaultModel.repoID)
        }
    }

    @Test("Catalog repos are unique, resolvable, and sanely sized")
    func catalogIsConsistent() {
        let repos = MLXModelCatalog.models.map(\.repoID)
        #expect(Set(repos).count == repos.count)
        #expect(!MLXModelCatalog.models.isEmpty)
        for model in MLXModelCatalog.models {
            #expect(MLXModelCatalog.model(for: model.repoID) == model)
            #expect(model.approximateMegabytes > 0)
            #expect(model.minimumMemoryGigabytes > 0)
            #expect(model.repoID.contains("/"))
        }
        #expect(repos.contains(MLXModelCatalog.defaultModel.repoID))
    }

    @Test("Store directory follows the HubCache layout")
    func storeDirectoryMatchesLayout() {
        let model = MLXModelCatalog.models[0]
        let directory = MLXModelStore.repoDirectory(for: model)
        #expect(directory.path.hasSuffix("MLXModels/models--mlx-community--Qwen3-1.7B-4bit"))
    }
}

/// The JSON extractor is the local engine's structured-output backbone — a
/// reply it can't parse becomes a user-facing failure.
struct MLXJSONExtractionTests {
    @MainActor
    private func extract(_ text: String) -> String? {
        MLXSummarizationService.extractJSONObject(from: text).flatMap { String(data: $0, encoding: .utf8) }
    }

    @MainActor
    @Test("A bare JSON object passes through")
    func bareObject() {
        #expect(extract(#"{"a": 1}"#) == #"{"a": 1}"#)
    }

    @MainActor
    @Test("Markdown fences and prose around the object are ignored")
    func fencedObject() {
        let reply = """
        Here are the notes:
        ```json
        {"keyPoints": ["one"], "decisions": []}
        ```
        Hope this helps!
        """
        #expect(extract(reply) == #"{"keyPoints": ["one"], "decisions": []}"#)
    }

    @MainActor
    @Test("Think blocks are stripped, including braces inside them")
    func thinkBlockStripped() {
        let reply = #"<think>I should return {"draft": true} maybe</think>{"keyPoints": []}"#
        #expect(extract(reply) == #"{"keyPoints": []}"#)
    }

    @MainActor
    @Test("Nested objects and braces inside strings balance correctly")
    func nestedAndEscaped() {
        let json = #"{"a": {"b": "close } brace", "c": "quote \" here"}, "d": []}"#
        #expect(extract("noise " + json + " trailing") == json)
    }

    @MainActor
    @Test("No object yields nil")
    func noObject() {
        #expect(extract("no json here") == nil)
        #expect(extract("{unclosed") == nil)
    }

    @MainActor
    @Test("An unterminated think block is discarded, draft JSON and all")
    func unterminatedThinkDiscarded() {
        // Generation ran out of budget mid-reasoning: the inline draft must
        // not be mistaken for the answer.
        let reply = #"<think>Let me draft: {"overview": "wrong"} but wait, I should"#
        #expect(extract(reply) == nil)
    }

    @MainActor
    @Test("Text before an unterminated think block still parses")
    func unterminatedThinkKeepsPrefix() {
        let reply = #"{"keyPoints": []}<think>should I revise? Maybe {"keyPoints": ["x"]}"#
        #expect(extract(reply) == #"{"keyPoints": []}"#)
    }
}

/// When the merge (or a condense inside it) comes back unreadable, minutes of
/// on-device generation must not be thrown away: the chunk notes fold together
/// in code, exactly as the Apple engine degrades on a refusal.
struct MLXMechanicalFallbackTests {
    private func notes(
        keyPoints: [String]? = nil,
        decisions: [String]? = nil,
        actionItems: [LocalActionItem]? = nil,
        openQuestions: [String]? = nil,
        speakerPerspectives: [LocalPerspective]? = nil
    ) -> LocalChunkNotes {
        LocalChunkNotes(
            keyPoints: keyPoints,
            decisions: decisions,
            actionItems: actionItems,
            openQuestions: openQuestions,
            speakerPerspectives: speakerPerspectives
        )
    }

    @MainActor
    @Test("Overlapping parts fold into one set of notes")
    func combinesAndDedupes() {
        let combined = MLXSummarizationService.mechanicallyCombined([
            notes(
                keyPoints: ["Pricing is behind", "Pricing is behind"],
                decisions: ["Ship on Friday"],
                actionItems: [LocalActionItem(task: "Update the pricing page", owner: nil, deadline: nil)],
                openQuestions: ["Who owns the migration?"],
                speakerPerspectives: [LocalPerspective(speaker: "Ana", points: ["Wants a staged rollout"])]
            ),
            notes(
                keyPoints: ["pricing is behind", "Docs are stale"],
                actionItems: [LocalActionItem(task: "update the pricing page", owner: "Ana", deadline: "Friday")],
                speakerPerspectives: [LocalPerspective(speaker: "ana", points: ["Wants a staged rollout", "Needs the docs first"])]
            ),
        ])

        #expect(combined.keyPoints == ["Pricing is behind", "Docs are stale"])
        #expect(combined.decisions == ["Ship on Friday"])
        #expect(combined.openQuestions == ["Who owns the migration?"])
        // The repeat carries the owner and deadline the first copy lacked.
        #expect(combined.actionItems?.count == 1)
        #expect(combined.actionItems?.first?.task == "Update the pricing page")
        #expect(combined.actionItems?.first?.owner == "Ana")
        #expect(combined.actionItems?.first?.deadline == "Friday")
        #expect(combined.speakerPerspectives?.count == 1)
        #expect(combined.speakerPerspectives?.first?.points == ["Wants a staged rollout", "Needs the docs first"])
    }

    @MainActor
    @Test("The same task owned by two people stays two commitments")
    func conflictingOwnersAreNotMerged() {
        let combined = MLXSummarizationService.mechanicallyCombined([
            notes(actionItems: [LocalActionItem(task: "Send the deck", owner: "Ana", deadline: nil)]),
            notes(actionItems: [LocalActionItem(task: "Send the deck", owner: "Bo", deadline: nil)]),
        ])
        #expect(combined.actionItems?.count == 2)
    }

    @MainActor
    @Test("The fallback summary keeps every fact and claims nothing extra")
    func fallbackSummaryHasNoOverviewOrTitle() {
        let summary = MLXSummarizationService.mechanicalSummary(from: [
            notes(
                keyPoints: ["Pricing is behind"],
                decisions: ["Ship on Friday"],
                actionItems: [LocalActionItem(task: "Update the pricing page", owner: nil, deadline: nil)],
                openQuestions: ["Who owns the migration?"]
            ),
        ])

        // No model wrote these, so the summary must not pretend otherwise.
        #expect(summary.overview.isEmpty)
        #expect(summary.suggestedTitle == nil)
        #expect(summary.keyPoints == ["Pricing is behind"])
        #expect(summary.decisions == ["Ship on Friday"])
        #expect(summary.openQuestions == ["Who owns the migration?"])
        // A missing owner is the literal placeholder, never a blank.
        #expect(summary.actionItems == [
            ActionItem(task: "Update the pricing page", owner: ActionItem.notSpecified, deadline: ActionItem.notSpecified)
        ])
        #expect(summary.speakerPerspectives == nil)
    }
}
