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
