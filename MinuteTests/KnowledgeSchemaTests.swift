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

    @Test func visibleFactsExcludeTombstonesAndHistorySortedNewestFirst() throws {
        let context = try makeContainer().mainContext
        let entity = KnowledgeEntity(name: "Sarah", kind: .person)
        context.insert(entity)
        let old = KnowledgeFact(text: "old", originalText: "old", status: .approved,
                                sourceMeetingID: UUID(), capturedAt: .now.addingTimeInterval(-3600), entity: entity)
        let new = KnowledgeFact(text: "new", originalText: "new", status: .autoCaptured,
                                sourceMeetingID: UUID(), capturedAt: .now, entity: entity)
        let draft = KnowledgeFact(text: "draft", originalText: "draft", status: .suggested,
                                  sourceMeetingID: UUID(), capturedAt: .now.addingTimeInterval(-60), entity: entity)
        let gone = KnowledgeFact(text: "", originalText: "", status: .rejected,
                                 sourceMeetingID: UUID(), capturedAt: .now, entity: entity)
        let past = KnowledgeFact(text: "past", originalText: "past", status: .superseded,
                                 sourceMeetingID: UUID(), capturedAt: .now, entity: entity)
        for fact in [old, new, draft, gone, past] { context.insert(fact) }
        try context.save()

        #expect(entity.visibleFacts.map(\.text) == ["new", "draft", "old"])
        // Settled = visible minus drafts — what unbadged surfaces may speak.
        #expect(entity.settledFacts.map(\.text) == ["new", "old"])
    }

    @Test func factCreatedAtDefaultsNowAndToleratesNilFromM1Rows() throws {
        let context = try makeContainer().mainContext
        let entity = KnowledgeEntity(name: "Atlas", kind: .project)
        context.insert(entity)
        let fresh = KnowledgeFact(text: "f", originalText: "f", status: .approved,
                                  sourceMeetingID: UUID(), capturedAt: .now, entity: entity)
        context.insert(fresh)
        #expect(fresh.createdAt != nil)
        fresh.createdAt = nil   // an m1-era row after migration
        try context.save()
        #expect(try context.fetch(FetchDescriptor<KnowledgeFact>()).count == 1)
        #expect(entity.synthesizedFactCount == nil)
    }
    @Test func factsWrittenBeforeSourcesGetThemBuiltFromTheOldColumns() throws {
        let context = try makeContainer().mainContext
        let source = Meeting(title: "Source", createdAt: .now.addingTimeInterval(-7200))
        let restater = Meeting(title: "Restater")
        context.insert(source)
        context.insert(restater)
        let entity = KnowledgeEntity(name: "Sarah", kind: .person)
        context.insert(entity)
        // Exactly how a row looks after the lightweight migration: the old
        // columns carry the data and `sources` is empty.
        let fact = KnowledgeFact(
            text: "Sarah leads Atlas", originalText: "Sarah leads Atlas",
            status: .autoCaptured, sources: [], entity: entity
        )
        fact.legacySourceMeetingID = source.id
        fact.legacySourceQuote = "I'm leading Atlas"
        fact.legacyCapturedAt = source.createdAt
        fact.legacyCorroboratedByMeetingIDs = [restater.id]
        context.insert(fact)
        try context.save()

        #expect(KnowledgeMigration.backfillSources(context: context))

        #expect(fact.sourceMeetingIDs == [source.id, restater.id])
        // The primary keeps its validated quote.
        #expect(fact.sources.first?.quote == "I'm leading Atlas")
        // A corroborator never had a date of its own; its meeting's real date
        // is used rather than inheriting the primary's.
        #expect(fact.sources.last?.capturedAt == restater.createdAt)
        #expect(fact.sources.last?.quote == nil)
        // capturedAt is derived, so it follows the newest statement.
        #expect(fact.capturedAt == restater.createdAt)

        // The legacy copies were consumed into `sources` and scrubbed, so a
        // later deletion never has to remember to clear a second copy of the
        // quote, and a re-run has no corroborators to duplicate.
        #expect(fact.legacySourceQuote == nil)
        #expect(fact.legacyCorroboratedByMeetingIDs == nil)

        // Idempotent: a second pass leaves a fact that already has sources alone.
        #expect(KnowledgeMigration.backfillSources(context: context))
        #expect(fact.sources.count == 2)
    }

    /// The one migration failure lightweight migration cannot survive is a
    /// mandatory attribute added without a default: existing rows have no value
    /// to fill it with, store creation fails, and MinuteApp silently falls back
    /// to in-memory storage — an upgrading user loses persistence. `sources`
    /// shipped that way once; this pins the default so it cannot again.
    @Test func sourcesCarriesADefaultSoExistingStoresCanMigrate() throws {
        let schema = Schema([Meeting.self, KnowledgeEntity.self, KnowledgeFact.self])
        let fact = try #require(schema.entities.first { $0.name == "KnowledgeFact" })
        let sources = try #require(fact.attributes.first { $0.name == "sources" })
        #expect(!sources.isOptional)
        #expect(sources.defaultValue != nil)
    }

}
