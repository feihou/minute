import Foundation
import SwiftData
import Testing
@testable import Minute

@MainActor
struct KnowledgeSchemaTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Meeting.self, KnowledgeEntity.self, KnowledgeFact.self,
            configurations: MeetingStore.modelConfiguration(inMemory: true)
        )
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

        let old = try ModelContainer(
            for: Meeting.self,
            configurations: ModelConfiguration(url: url, cloudKitDatabase: .none)
        )
        old.mainContext.insert(Meeting(title: "Pre-upgrade"))
        try old.mainContext.save()

        let new = try ModelContainer(
            for: Meeting.self, KnowledgeEntity.self, KnowledgeFact.self,
            configurations: ModelConfiguration(url: url, cloudKitDatabase: .none)
        )
        let meetings = try new.mainContext.fetch(FetchDescriptor<Meeting>())
        #expect(meetings.count == 1)
        #expect(meetings[0].knowledgeExtractedAt == nil)
    }
}
