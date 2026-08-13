import Foundation
import SwiftData
import Testing
@testable import Minute

@MainActor
struct BrainSectionsTests {
    private static var retainedContainers: [ModelContainer] = []

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Meeting.self, KnowledgeEntity.self, KnowledgeFact.self,
            configurations: MeetingStore.modelConfiguration(inMemory: true)
        )
        Self.retainedContainers.append(container)
        return container.mainContext
    }

    private func entity(_ name: String, _ kind: EntityKind, factAge: TimeInterval?, context: ModelContext, redirected: Bool = false) -> KnowledgeEntity {
        let entity = KnowledgeEntity(name: name, kind: kind)
        if redirected { entity.redirectTo = UUID() }
        context.insert(entity)
        if let factAge {
            context.insert(KnowledgeFact(
                text: "\(name) fact", originalText: "\(name) fact", status: .autoCaptured,
                sourceMeetingID: UUID(), capturedAt: .now.addingTimeInterval(-factAge), entity: entity
            ))
        }
        return entity
    }

    @Test func groupsByKindHidesFactlessAndRedirectedSortsByFreshness() throws {
        let context = try makeContext()
        let me = entity("Me", .me, factAge: nil, context: context)
        _ = entity("Stale Person", .person, factAge: 3600, context: context)
        _ = entity("Fresh Person", .person, factAge: 60, context: context)
        _ = entity("Factless", .person, factAge: nil, context: context)
        _ = entity("Merged Away", .person, factAge: 60, context: context, redirected: true)
        _ = entity("Atlas", .project, factAge: 120, context: context)
        _ = entity("Pricing", .topic, factAge: 240, context: context)
        try context.save()

        let sections = BrainSections.grouped(try context.fetch(FetchDescriptor<KnowledgeEntity>()))

        #expect(sections.me?.id == me.id)                       // Me shows even factless
        #expect(sections.people.map(\.name) == ["Fresh Person", "Stale Person"])
        #expect(sections.projects.map(\.name) == ["Atlas"])
        #expect(sections.topics.map(\.name) == ["Pricing"])
    }
}
