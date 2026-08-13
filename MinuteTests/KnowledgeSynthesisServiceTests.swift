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

        await KnowledgeSynthesisService.refreshIfStale(entity, context: context)

        #expect(entity.synthesis == nil)
        #expect(entity.synthesizedFactCount == 0)
    }
}
