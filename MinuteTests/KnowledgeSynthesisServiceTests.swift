import Foundation
import SwiftData
import Testing
@testable import Minute

@MainActor
struct KnowledgeSynthesisServiceTests {
    /// ModelContainer teardown races crash the test host — retained for the
    /// process lifetime, same pattern as KnowledgeSchemaTests.
    private static var retainedContainers: [ModelContainer] = []

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Meeting.self, KnowledgeEntity.self, KnowledgeFact.self,
            configurations: MeetingStore.modelConfiguration(inMemory: true)
        )
        Self.retainedContainers.append(container)
        return container.mainContext
    }

    private func entityWithFacts(_ count: Int, context: ModelContext) -> KnowledgeEntity {
        let entity = KnowledgeEntity(name: "Sarah", kind: .person)
        context.insert(entity)
        for index in 0..<count {
            context.insert(KnowledgeFact(
                text: "fact \(index)", originalText: "fact \(index)", status: .autoCaptured,
                sourceMeetingID: UUID(), capturedAt: .now, entity: entity
            ))
        }
        return entity
    }

    @Test func staleWhenNeverSynthesizedOrCountDrifts() throws {
        let context = try makeContext()
        let entity = entityWithFacts(2, context: context)
        try context.save()

        #expect(KnowledgeSynthesisService.isStale(entity))       // never synthesized
        entity.synthesizedFactCount = 2
        #expect(!KnowledgeSynthesisService.isStale(entity))      // in sync
        entity.synthesizedFactCount = 1
        #expect(KnowledgeSynthesisService.isStale(entity))       // drifted
    }

    @Test func refreshWithNoVisibleFactsClearsTheNarrativeWithoutTheModel() async throws {
        let context = try makeContext()
        let entity = KnowledgeEntity(name: "Ghost", kind: .topic)
        entity.synthesis = "left over"
        context.insert(entity)
        try context.save()

        let fresh = await KnowledgeSynthesisService.refreshIfStale(entity, context: context)

        #expect(fresh == true)
        #expect(entity.synthesis == nil)
        #expect(entity.synthesizedFactCount == 0)
    }

    @Test func draftOnlyEntityGetsNoNarrative() async throws {
        let context = try makeContext()
        let entity = KnowledgeEntity(name: "New Person", kind: .person)
        entity.synthesis = "stale prose"
        context.insert(entity)
        context.insert(KnowledgeFact(
            text: "unreviewed", originalText: "unreviewed", status: .suggested,
            sourceMeetingID: UUID(), capturedAt: .now, entity: entity
        ))
        try context.save()

        var calls = 0
        let fresh = await KnowledgeSynthesisService.refreshIfStale(entity, context: context) { _, _, _ in
            calls += 1
            return "never"
        }

        // Drafts are badged individually on the page — they must never be
        // narrated as established knowledge, so a draft-only entity clears.
        #expect(fresh == true)
        #expect(calls == 0)
        #expect(entity.synthesis == nil)
        #expect(entity.synthesizedFactCount == 0)
    }

    @Test func factsReplacedMidSynthesisAreResynthesizedNotStampedStale() async throws {
        let context = try makeContext()
        let entity = KnowledgeEntity(name: "Sarah", kind: .person)
        context.insert(entity)
        let original = KnowledgeFact(
            text: "old fact", originalText: "old fact", status: .autoCaptured,
            sourceMeetingID: UUID(), capturedAt: .now, entity: entity
        )
        context.insert(original)
        try context.save()

        var calls = 0
        let fresh = await KnowledgeSynthesisService.refreshIfStale(entity, context: context) { _, _, facts in
            calls += 1
            if calls == 1 {
                // A same-count re-extraction lands while the model is
                // writing: marker stays nil-to-nil, so no new view task
                // starts — this continuation must notice, not commit.
                context.delete(original)
                context.insert(KnowledgeFact(
                    text: "new fact", originalText: "new fact", status: .autoCaptured,
                    sourceMeetingID: UUID(), capturedAt: .now, entity: entity
                ))
                try? context.save()
            }
            return "narrative from \(facts.joined())"
        }

        #expect(fresh == true)
        #expect(calls == 2)
        #expect(entity.synthesis == "narrative from new fact")
        #expect(entity.synthesizedFactCount == 1)
    }

    @Test func failedSynthesisReportsFalseAndKeepsPriorState() async throws {
        let context = try makeContext()
        let entity = entityWithFacts(2, context: context)
        entity.synthesis = "previous narrative"
        entity.synthesizedFactCount = 1   // stale
        try context.save()

        struct Boom: Error {}
        let fresh = await KnowledgeSynthesisService.refreshIfStale(entity, context: context) { _, _, _ in
            throw Boom()
        }

        #expect(fresh == false)
        #expect(entity.synthesis == "previous narrative")
        #expect(entity.synthesizedFactCount == 1)
    }

    @Test func upToDateEntityReportsTrueWithoutCallingTheModel() async throws {
        let context = try makeContext()
        let entity = entityWithFacts(2, context: context)
        entity.synthesizedFactCount = 2
        try context.save()

        var calls = 0
        let fresh = await KnowledgeSynthesisService.refreshIfStale(entity, context: context) { _, _, _ in
            calls += 1
            return "should not be called"
        }

        #expect(fresh == true)
        #expect(calls == 0)
    }
}
