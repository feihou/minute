import Foundation
import SwiftData
import Testing
@testable import Minute

@MainActor
struct KnowledgeSchemaTests {
    /// Containers with the relationship-bearing knowledge schema are retained
    /// for the process lifetime: ModelContainer teardown is not actor-isolated,
    /// and a container deiniting in the background while another test runs
    /// crashes the test host inside SwiftData.framework (signal trap; see
    /// .superpowers/sdd/task-1-report.md). Tests still get a fresh, isolated
    /// container each — they just never tear it down mid-run.
    private static var retainedContainers: [ModelContainer] = []

    @discardableResult
    private static func retain(_ container: ModelContainer) -> ModelContainer {
        retainedContainers.append(container)
        return container
    }

    private func makeContainer() throws -> ModelContainer {
        try Self.retain(ModelContainer(
            for: Meeting.self, KnowledgeEntity.self, KnowledgeFact.self,
            configurations: MeetingStore.modelConfiguration(inMemory: true)
        ))
    }

    @Test func entityCascadeDeletesItsFacts() throws {
        let context = try makeContainer().mainContext
        let entity = KnowledgeEntity(name: "Atlas", kind: .project)
        context.insert(entity)
        let fact = KnowledgeFact(
            text: "Atlas ships in Q3", originalText: "Atlas ships in Q3",
            status: .autoCaptured, sourceMeetingID: UUID(), capturedAt: .now, entity: entity
        )
        context.insert(fact)
        try context.save()

        context.delete(entity)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<KnowledgeFact>()).isEmpty)
    }

    @Test func statusAndKindRoundTripThroughRawStorage() throws {
        let context = try makeContainer().mainContext
        let entity = KnowledgeEntity(name: "Sarah Chen", kind: .person)
        context.insert(entity)
        let fact = KnowledgeFact(
            text: "t", originalText: "t", status: .suggested,
            sourceMeetingID: UUID(), capturedAt: .now, entity: entity
        )
        context.insert(fact)
        fact.status = .approved
        try context.save()

        #expect(entity.kind == .person)
        #expect(fact.status == .approved)
        #expect(fact.statusRaw == "approved")
    }

    /// Opens an on-disk store created with the CURRENT schema (Meeting only)
    /// using the NEW schema — the lightweight migration every existing user
    /// goes through. A KB schema bug must never take meetings down.
    @Test func existingMeetingStoreMigratesToKnowledgeSchema() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("migrate-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: url) }

        let old = try Self.retain(ModelContainer(
            for: Meeting.self,
            configurations: ModelConfiguration(url: url, cloudKitDatabase: .none)
        ))
        old.mainContext.insert(Meeting(title: "Pre-upgrade"))
        try old.mainContext.save()

        let new = try Self.retain(ModelContainer(
            for: Meeting.self, KnowledgeEntity.self, KnowledgeFact.self,
            configurations: ModelConfiguration(url: url, cloudKitDatabase: .none)
        ))
        let meetings = try new.mainContext.fetch(FetchDescriptor<Meeting>())
        #expect(meetings.count == 1)
        #expect(meetings[0].knowledgeExtractedAt == nil)
    }
}
